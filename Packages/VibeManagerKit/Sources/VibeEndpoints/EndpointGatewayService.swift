import Darwin
import Foundation
import VibeDomain

/// The gateway as a program: what `Vibe Manager --endpoint-gateway <directory>` runs (#107).
///
/// One per data folder, held by a lock taken before listening: a second one finds it held and
/// leaves. It listens on the port it had last time when it can, so that an agent started before a
/// restart of the gateway still reaches it, and it stops by itself once no session token is left
/// for a minute: the application removes the tokens of the sessions that ended.
public enum EndpointGatewayService {
  public static let argument = "--endpoint-gateway"

  public enum Outcome: Equatable, Sendable {
    case alreadyRunning
    case idle
  }

  public static func run(
    location: GatewayLocation,
    router: FileGatewayRouter,
    transport: any EndpointTransport = URLSessionEndpointTransport(),
    observer: (any GatewayObserving)? = nil,
    idleCheck: Duration = .seconds(30),
    idleChecksBeforeExit: Int = 2
  ) async throws -> Outcome {
    try location.prepare()
    let lock = open(location.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lock >= 0 else { return .alreadyRunning }
    // The application checks the lock by taking it for an instant: a few more tries tell that
    // from a gateway already running.
    var locked = flock(lock, LOCK_EX | LOCK_NB) == 0
    for _ in 0..<20 where !locked {
      try await Task.sleep(for: .milliseconds(25))
      locked = flock(lock, LOCK_EX | LOCK_NB) == 0
    }
    guard locked else {
      close(lock)
      return .alreadyRunning
    }
    // What a gateway that crashed left behind names a port that may be anyone's by now.
    try? FileManager.default.removeItem(at: location.stateURL)
    defer {
      try? FileManager.default.removeItem(at: location.stateURL)
      flock(lock, LOCK_UN)
      close(lock)
    }
    let journal = GatewayStepJournal(
      directory: location.directory, session: { await router.session(for: $0) })
    let gateway = Gateway(routes: router, transport: transport, observer: observer ?? journal)
    let (server, port) = try await listen(
      preferring: GatewayState.read(location.stateURL)?.port, gateway: gateway)
    defer { server.stop() }
    try GatewayState(processIdentifier: getpid(), port: port).write(to: location.stateURL)

    var idleChecks = 0
    while true {
      try await Task.sleep(for: idleCheck)
      if await router.count() == 0 {
        idleChecks += 1
        if idleChecks >= idleChecksBeforeExit { return .idle }
      } else {
        idleChecks = 0
      }
    }
  }

  /// The previous port first: agents that were told it keep working.
  private static func listen(preferring port: UInt16?, gateway: Gateway) async throws
    -> (GatewayHTTPServer, UInt16)
  {
    if let port, port != 0 {
      if let server = try? GatewayHTTPServer(port: port, handler: gateway),
        let bound = try? await server.start()
      {
        return (server, bound)
      }
    }
    let server = try GatewayHTTPServer(port: 0, handler: gateway)
    return (server, try await server.start())
  }
}

/// The gateway seen from the application: started when a session needs it, told which tokens lead
/// where, and relieved of the tokens of the sessions that ended.
public actor EndpointGatewayController {
  private let location: GatewayLocation
  private let launch: @Sendable () throws -> Void
  private let now: @Sendable () -> Date
  private let startupLimit: Duration

  /// - Parameter launch: starts `Vibe Manager --endpoint-gateway <directory>`, detached.
  public init(
    location: GatewayLocation,
    launch: @escaping @Sendable () throws -> Void,
    now: @escaping @Sendable () -> Date = Date.init,
    startupLimit: Duration = .seconds(5)
  ) {
    self.location = location
    self.launch = launch
    self.now = now
    self.startupLimit = startupLimit
  }

  /// Whether a gateway runs for this folder: its lock is held. Not its process number, which a
  /// gateway that crashed leaves behind in `gateway.json` for another process to be given.
  public static func isRunning(at location: GatewayLocation) -> Bool {
    let lock = open(location.lockURL.path, O_RDWR | O_CLOEXEC)
    guard lock >= 0 else { return false }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
    flock(lock, LOCK_UN)
    return false
  }

  public enum ControlError: Error, Equatable {
    case didNotStart
  }

  /// The running gateway's base URL, after starting it when needed.
  public func ensureRunning() async throws -> URL {
    if let url = await runningURL() { return url }
    try location.prepare()
    try launch()
    let clock = ContinuousClock()
    let deadline = clock.now + startupLimit
    while clock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      if let url = await runningURL() { return url }
    }
    throw ControlError.didNotStart
  }

  /// The gateway's address, when it runs and answers there as itself.
  private func runningURL() async -> URL? {
    guard Self.isRunning(at: location), let state = GatewayState.read(location.stateURL) else {
      return nil
    }
    var request = URLRequest(url: state.baseURL.appendingPathComponent("health"))
    request.httpMethod = "HEAD"
    request.timeoutInterval = 2
    guard let (_, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: Gateway.identityHeader) != nil
    else { return nil }
    return state.baseURL
  }

  /// Lets `token` through. The tokens of a previous launch of the same session are forgotten.
  public func register(token: String, endpoint: EndpointID, model: String, session: SessionID?)
    throws
  {
    try location.prepare()
    var document = GatewayRoutesDocument.read(location.routesURL)
    if let session {
      document.routes = document.routes.filter { $0.value.session != session }
    }
    document.routes[token] = GatewayRoutesDocument.Route(
      endpoint: endpoint, model: model, session: session, createdAt: now())
    try document.write(to: location.routesURL)
  }

  /// Forgets the tokens of sessions not in `sessions`. A token given without a session — a one-off
  /// run, a test of the endpoint — is kept a day.
  public func retain(sessions: Set<SessionID>) throws {
    var document = GatewayRoutesDocument.read(location.routesURL)
    let before = document.routes.count
    let dayAgo = now().addingTimeInterval(-86_400)
    // A session is marked running only once its process started: a token given a moment ago
    // belongs to a launch still under way.
    let justGiven = now().addingTimeInterval(-120)
    document.routes = document.routes.filter { _, route in
      if route.createdAt > justGiven { return true }
      if let session = route.session { return sessions.contains(session) }
      return route.createdAt > dayAgo
    }
    // The settings files of the sessions gone, which carried their tokens (#107).
    let settings = location.directory.appendingPathComponent("settings", isDirectory: true)
    let kept = Set(
      (Array(sessions) + document.routes.values.compactMap(\.session)).map {
        "\($0.rawValue.uuidString).json"
      })
    for name in (try? FileManager.default.contentsOfDirectory(atPath: settings.path)) ?? []
    where !kept.contains(name) {
      try? FileManager.default.removeItem(at: settings.appendingPathComponent(name))
    }
    guard document.routes.count != before else { return }
    try document.write(to: location.routesURL)
  }

  public func tokenCount() -> Int {
    GatewayRoutesDocument.read(location.routesURL).routes.count
  }

  /// A token no one can guess: 256 random bits, as hexadecimal.
  public static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
  }
}
