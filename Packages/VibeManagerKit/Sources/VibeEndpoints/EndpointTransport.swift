import Foundation

/// A request from the gateway to an endpoint.
public struct EndpointHTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data?

  public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil)
  {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

/// An endpoint's answer: its status and headers as soon as they arrive, its body as it streams.
public struct EndpointHTTPResponse: Sendable {
  public var status: Int
  /// Header names in lowercase.
  public var headers: [String: String]
  public var body: AsyncThrowingStream<Data, any Error>

  public init(
    status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>
  ) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  /// The whole body, for answers that do not stream and for error bodies, capped so that an
  /// endpoint answering a gigabyte cannot fill the memory.
  public func collect(limit: Int = 32 * 1_024 * 1_024) async throws -> Data {
    var data = Data()
    for try await chunk in body {
      data.append(chunk)
      if data.count > limit {
        throw EndpointFailure(kind: .malformedResponse, message: "The answer is too large.")
      }
    }
    return data
  }
}

/// How long the gateway waits on an endpoint.
public struct EndpointTimeouts: Hashable, Codable, Sendable {
  /// To open the connection and send the request.
  public var connect: Duration
  /// From the request sent to the status line: a local model loading in memory takes long here.
  public var firstByte: Duration
  /// Between two pieces of a streamed answer.
  public var idle: Duration
  /// For a whole answer.
  public var total: Duration

  public init(
    connect: Duration = .seconds(10), firstByte: Duration = .seconds(120),
    idle: Duration = .seconds(60), total: Duration = .seconds(900)
  ) {
    self.connect = connect
    self.firstByte = firstByte
    self.idle = idle
    self.total = total
  }

  public static let standard = EndpointTimeouts()
}

public protocol EndpointTransport: Sendable {
  func send(_ request: EndpointHTTPRequest, timeouts: EndpointTimeouts) async throws
    -> EndpointHTTPResponse
}

/// The transport to real endpoints.
///
/// A delegate rather than `bytes(for:)`: the body arrives in the chunks the network delivers, not
/// byte by byte, and the silence between two of them can be timed. Cookies, caches and credentials
/// of the shared session are all off: an endpoint sees only what the gateway sends.
public final class URLSessionEndpointTransport: NSObject, EndpointTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Int: TaskState] = [:]
  private var session: URLSession?

  private final class TaskState: @unchecked Sendable {
    var head: CheckedContinuation<EndpointHTTPResponse, any Error>?
    var body: AsyncThrowingStream<Data, any Error>.Continuation?
    var bodyStream: AsyncThrowingStream<Data, any Error>?
    var watchdog: Task<Void, Never>?
    var lastActivity = ContinuousClock.now
    var timeouts: EndpointTimeouts

    init(timeouts: EndpointTimeouts) {
      self.timeouts = timeouts
    }
  }

  public override init() {
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Timed here rather than by `URLSession`, whose single request timeout mixes them all.
    configuration.timeoutIntervalForRequest = 3_600
    configuration.timeoutIntervalForResource = 3_600
    configuration.httpMaximumConnectionsPerHost = 16
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  public func invalidate() {
    session?.invalidateAndCancel()
  }

  public func send(_ request: EndpointHTTPRequest, timeouts: EndpointTimeouts) async throws
    -> EndpointHTTPResponse
  {
    guard let session else {
      throw EndpointFailure(kind: .network, message: "The gateway is shutting down.")
    }
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    let task = session.dataTask(with: urlRequest)
    let state = TaskState(timeouts: timeouts)
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .unbounded)
    // Nobody reads the body any more — an answer too large, a decoder that gave up, a cancelled
    // turn: the request stops, rather than keep downloading into a buffer.
    continuation.onTermination = { _ in task.cancel() }
    state.body = continuation
    state.bodyStream = stream
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { head in
        state.head = head
        store(state, for: task.taskIdentifier)
        state.watchdog = Task { [weak self] in
          await self?.watch(task: task, state: state)
        }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  private func store(_ state: TaskState, for identifier: Int) {
    lock.lock()
    tasks[identifier] = state
    lock.unlock()
  }

  private func state(for identifier: Int) -> TaskState? {
    lock.lock()
    defer { lock.unlock() }
    return tasks[identifier]
  }

  private func remove(_ identifier: Int) -> TaskState? {
    lock.lock()
    defer { lock.unlock() }
    return tasks.removeValue(forKey: identifier)
  }

  /// Ends a task that went silent: before its head, after `firstByte`; while streaming, after
  /// `idle`; in any case after `total`.
  private func watch(task: URLSessionDataTask, state: TaskState) async {
    let clock = ContinuousClock()
    let started = clock.now
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(250))
      let (hasHead, last) = synchronized { (state.head == nil, state.lastActivity) }
      let now = clock.now
      let limit = hasHead ? state.timeouts.idle : state.timeouts.firstByte
      let failure: EndpointFailure?
      if now - started > state.timeouts.total {
        failure = EndpointFailure(kind: .timeout, message: "The endpoint took too long to answer.")
      } else if now - last > limit {
        failure = EndpointFailure(
          kind: .timeout,
          message: hasHead
            ? "The endpoint stopped sending its answer." : "The endpoint did not answer in time.")
      } else {
        failure = nil
      }
      if let failure {
        fail(task.taskIdentifier, with: failure)
        task.cancel()
        return
      }
    }
  }

  private func synchronized<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func fail(_ identifier: Int, with failure: any Error) {
    guard let state = remove(identifier) else { return }
    state.watchdog?.cancel()
    let head = synchronized { () -> CheckedContinuation<EndpointHTTPResponse, any Error>? in
      defer { state.head = nil }
      return state.head
    }
    head?.resume(throwing: failure)
    state.body?.finish(throwing: failure)
  }
}

extension URLSessionEndpointTransport: URLSessionDataDelegate {
  public func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let state = state(for: dataTask.taskIdentifier), let stream = state.bodyStream else {
      completionHandler(.cancel)
      return
    }
    let http = response as? HTTPURLResponse
    var headers: [String: String] = [:]
    for (name, value) in http?.allHeaderFields ?? [:] {
      if let name = name as? String, let value = value as? String {
        headers[name.lowercased()] = value
      }
    }
    let head = synchronized { () -> CheckedContinuation<EndpointHTTPResponse, any Error>? in
      state.lastActivity = .now
      defer { state.head = nil }
      return state.head
    }
    head?.resume(
      returning: EndpointHTTPResponse(
        status: http?.statusCode ?? 0, headers: headers, body: stream))
    completionHandler(.allow)
  }

  public func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
  ) {
    guard let state = state(for: dataTask.taskIdentifier) else { return }
    synchronized { state.lastActivity = .now }
    state.body?.yield(data)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    guard let error else {
      guard let state = remove(task.taskIdentifier) else { return }
      state.watchdog?.cancel()
      state.body?.finish()
      return
    }
    fail(task.taskIdentifier, with: Self.failure(for: error))
  }

  static func failure(for error: any Error) -> EndpointFailure {
    let code = (error as? URLError)?.code
    switch code {
    case .cannotConnectToHost?, .cannotFindHost?, .dnsLookupFailed?:
      return EndpointFailure(kind: .network, message: "The endpoint cannot be reached.")
    case .networkConnectionLost?, .notConnectedToInternet?:
      return EndpointFailure(kind: .network, message: "The connection to the endpoint was lost.")
    case .timedOut?:
      return EndpointFailure(kind: .timeout, message: "The endpoint did not answer in time.")
    case .serverCertificateUntrusted?, .serverCertificateHasBadDate?,
      .serverCertificateNotYetValid?, .serverCertificateHasUnknownRoot?,
      .secureConnectionFailed?:
      return EndpointFailure(
        kind: .permission, message: "The endpoint's certificate is not trusted.")
    case .cancelled?:
      return EndpointFailure(kind: .network, message: "The request was cancelled.")
    default:
      return EndpointFailure(kind: .network, message: "The request to the endpoint failed.")
    }
  }
}
