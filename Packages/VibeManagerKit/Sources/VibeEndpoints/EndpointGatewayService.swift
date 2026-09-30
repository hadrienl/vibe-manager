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
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      if lock >= 0 { close(lock) }
      return .alreadyRunning
    }
    defer {
      try? FileManager.default.removeItem(at: location.stateURL)
      flock(lock, LOCK_UN)
      close(lock)
    }
    let gateway = Gateway(routes: router, transport: transport, observer: observer)
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
  private let isAlive: @Sendable (Int32) -> Bool
  private let startupLimit: Duration

  /// - Parameter launch: starts `Vibe Manager --endpoint-gateway <directory>`, detached.
  public init(
    location: GatewayLocation,
    launch: @escaping @Sendable () throws -> Void,
    now: @escaping @Sendable () -> Date = Date.init,
    isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 },
    startupLimit: Duration = .seconds(5)
  ) {
    self.location = location
    self.launch = launch
    self.now = now
    self.isAlive = isAlive
    self.startupLimit = startupLimit
  }

  public enum ControlError: Error, Equatable {
    case didNotStart
  }

  /// The running gateway's base URL, after starting it when needed.
  public func ensureRunning() async throws -> URL {
    if let state = GatewayState.read(location.stateURL), isAlive(state.processIdentifier) {
      return state.baseURL
    }
    try location.prepare()
    try launch()
    let clock = ContinuousClock()
    let deadline = clock.now + startupLimit
    while clock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      if let state = GatewayState.read(location.stateURL), isAlive(state.processIdentifier) {
        return state.baseURL
      }
    }
    throw ControlError.didNotStart
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
    document.routes = document.routes.filter { _, route in
      if let session = route.session { return sessions.contains(session) }
      return route.createdAt > dayAgo
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
