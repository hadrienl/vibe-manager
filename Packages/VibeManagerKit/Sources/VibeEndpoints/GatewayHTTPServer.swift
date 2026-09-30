import Foundation
import Network

/// A request a harness sent to the gateway.
public struct GatewayHTTPRequest: Sendable {
  public var method: String
  /// The path, without the query.
  public var path: String
  public var query: String?
  /// Header names in lowercase.
  public var headers: [String: String]
  public var body: Data

  public init(
    method: String, path: String, query: String? = nil, headers: [String: String] = [:],
    body: Data = Data()
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
  }
}

/// Where the gateway writes its answer: a status and headers once, then the body in pieces.
public protocol GatewayResponseWriter: Sendable {
  func start(status: Int, headers: [String: String]) async
  func write(_ data: Data) async
  func finish() async
}

public protocol GatewayRequestHandling: Sendable {
  func handle(_ request: GatewayHTTPRequest, writer: any GatewayResponseWriter) async
}

extension GatewayResponseWriter {
  /// A whole JSON answer.
  public func respond(status: Int, json: JSONValue) async {
    let body = json.data()
    await start(
      status: status,
      headers: ["content-type": "application/json", "content-length": String(body.count)])
    await write(body)
    await finish()
  }
}

/// A minimal HTTP/1.1 server on the loopback interface.
///
/// Just what a harness needs to reach the gateway: one request per connection, a body read by its
/// length or its chunks, and an answer that may stream until the connection closes. The two CLIs
/// it serves send nothing else. Anything that does not parse closes the connection; nothing is
/// ever logged of what went through, which carries prompts and code.
public final class GatewayHTTPServer: Sendable {
  public enum ServerError: Error, Equatable {
    case couldNotListen(String)
  }

  /// A request head or body larger than this is refused: a conversation of an agent runs to a few
  /// megabytes, images included, far below it.
  static let maximumRequestBytes = 64 * 1_024 * 1_024

  private let listener: NWListener
  private let handler: any GatewayRequestHandling
  private let queue = DispatchQueue(label: "com.hadrienl.VibeManager.gateway.server")

  /// Listens on `127.0.0.1:port`; port 0 lets the system choose.
  public init(port: UInt16, handler: any GatewayRequestHandling) throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.acceptLocalOnly = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw ServerError.couldNotListen(String(describing: error))
    }
    self.handler = handler
  }

  /// Starts listening and returns the port actually bound.
  public func start() async throws -> UInt16 {
    let listener = self.listener
    let handler = self.handler
    let queue = self.queue
    listener.newConnectionHandler = { connection in
      GatewayConnection(connection: connection, handler: handler, queue: queue).run()
    }
    return try await withCheckedThrowingContinuation { continuation in
      let resumed = ResumeOnce(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          resumed.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error):
          resumed.resume(throwing: ServerError.couldNotListen(String(describing: error)))
        case .cancelled:
          resumed.resume(throwing: ServerError.couldNotListen("cancelled"))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    listener.cancel()
  }
}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<UInt16, any Error>?

  init(_ continuation: CheckedContinuation<UInt16, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: UInt16) {
    take()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<UInt16, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let taken = continuation
    continuation = nil
    return taken
  }
}

/// One connection: its request read, handed to the handler, its answer written, then closed.
private final class GatewayConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let handler: any GatewayRequestHandling
  private let queue: DispatchQueue
  // Only touched from `queue`.
  private var buffer = Data()

  init(connection: NWConnection, handler: any GatewayRequestHandling, queue: DispatchQueue) {
    self.connection = connection
    self.handler = handler
    self.queue = queue
  }

  func run() {
    connection.start(queue: queue)
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) {
      [self] data, _, isComplete, error in
      if let data { buffer.append(data) }
      switch HTTPRequestParser.parse(buffer) {
      case .complete(let request):
        let writer = ConnectionWriter(connection: connection)
        let handler = self.handler
        Task {
          await handler.handle(request, writer: writer)
          await writer.finish()
        }
      case .invalid:
        reject(status: 400)
      case .tooLarge:
        reject(status: 413)
      case .incomplete:
        if error != nil || isComplete {
          connection.cancel()
        } else {
          receive()
        }
      }
    }
  }

  private func reject(status: Int) {
    let head =
      "HTTP/1.1 \(status) \(HTTPStatus.reason(status))\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { [connection] _ in connection.cancel() })
  }
}

/// Writes an answer on a connection, waiting for each piece to be handed to the network: a harness
/// that reads slowly slows the gateway, which slows its reading of the endpoint, rather than
/// letting an answer pile up in memory.
private actor ConnectionWriter: GatewayResponseWriter {
  private let connection: NWConnection
  private var started = false
  private var finished = false

  init(connection: NWConnection) {
    self.connection = connection
  }

  func start(status: Int, headers: [String: String]) async {
    guard !started else { return }
    started = true
    var head = "HTTP/1.1 \(status) \(HTTPStatus.reason(status))\r\n"
    var headers = headers
    headers["connection"] = "close"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    await send(Data(head.utf8))
  }

  func write(_ data: Data) async {
    guard !finished, !data.isEmpty else { return }
    if !started { await start(status: 200, headers: [:]) }
    await send(data)
  }

  func finish() async {
    guard !finished else { return }
    if !started { await start(status: 500, headers: ["content-length": "0"]) }
    finished = true
    let connection = self.connection
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      connection.send(
        content: nil, contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { _ in
          connection.cancel()
          continuation.resume()
        })
    }
  }

  private func send(_ data: Data) async {
    let connection = self.connection
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
    }
  }
}

enum HTTPStatus {
  static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    case 429: return "Too Many Requests"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    case 529: return "Overloaded"
    default: return "Status"
    }
  }
}

/// Parses one HTTP/1.1 request from the bytes received so far.
enum HTTPRequestParser {
  enum Result: Equatable {
    case incomplete
    case invalid
    case tooLarge
    case complete(GatewayHTTPRequest)
  }

  private static let headEnd = Data("\r\n\r\n".utf8)

  static func parse(_ data: Data) -> Result {
    guard let end = data.range(of: headEnd) else {
      return data.count > 64 * 1_024 ? .tooLarge : .incomplete
    }
    guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
      return .invalid
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { return .invalid }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let target = String(requestLine[1])
    let path: String
    let query: String?
    if let question = target.firstIndex(of: "?") {
      path = String(target[..<question])
      query = String(target[target.index(after: question)...])
    } else {
      path = target
      query = nil
    }
    let rest = data[end.upperBound...]
    let body: Data
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      switch dechunk(Data(rest)) {
      case .some(.some(let decoded)): body = decoded
      case .some(.none): return .incomplete
      case .none: return .invalid
      }
    } else if let length = headers["content-length"] {
      guard let count = Int(length), count >= 0 else { return .invalid }
      guard count <= GatewayHTTPServer.maximumRequestBytes else { return .tooLarge }
      guard rest.count >= count else { return .incomplete }
      body = Data(rest.prefix(count))
    } else {
      body = Data()
    }
    return .complete(
      GatewayHTTPRequest(
        method: String(requestLine[0]), path: path, query: query, headers: headers, body: body))
  }

  /// `nil` when invalid, `.some(nil)` when more bytes are needed.
  private static func dechunk(_ data: Data) -> Data?? {
    var output = Data()
    var index = data.startIndex
    let crlf = Data("\r\n".utf8)
    while true {
      guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return .some(nil) }
      guard let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii),
        let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16), size >= 0
      else { return nil }
      index = lineEnd.upperBound
      if size == 0 { return .some(output) }
      guard output.count + size <= GatewayHTTPServer.maximumRequestBytes else { return nil }
      guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return .some(nil) }
      let chunkEnd = data.index(index, offsetBy: size)
      output.append(data[index..<chunkEnd])
      index = data.index(chunkEnd, offsetBy: 2)
    }
  }
}

extension GatewayHTTPRequest: Equatable {}
