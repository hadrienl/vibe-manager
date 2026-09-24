import Darwin
import Foundation
import VibeApplication
import VibeDomain

/// The application's side of the terminal host: a `TerminalSupervisor` whose terminals run in
/// another process, so they can be left running when the application quits (ADR 0017).
///
/// Every terminal goes through the host — there is one road to a process, not two. When the host
/// cannot be started or will not prove it is ours, a terminal is started here instead, exactly as
/// before the host existed: it will stop with the application, and quitting says so, but a broken
/// host never keeps anybody from working.
public actor HostedTerminalSupervisor: TerminalSupervisor, TerminalHosting {
  public struct Configuration: Sendable {
    public var location: TerminalHostLocation
    /// `nil` never starts a host: only one already running is used.
    public var launcher: (any TerminalHostLaunching)?
    public var verifier: any TerminalHostPeerVerifier
    /// How long a host that was just started has to start listening. Generous: the host answers
    /// for itself to the system, and a binary the system has not assessed yet waits for it.
    public var launchTimeout: Duration
    /// How long any reply that is not a stop may take.
    public var replyTimeout: Duration

    public init(
      location: TerminalHostLocation,
      launcher: (any TerminalHostLaunching)?,
      verifier: any TerminalHostPeerVerifier,
      launchTimeout: Duration = .seconds(10),
      replyTimeout: Duration = .seconds(5)
    ) {
      self.location = location
      self.launcher = launcher
      self.verifier = verifier
      self.launchTimeout = launchTimeout
      self.replyTimeout = replyTimeout
    }
  }

  private enum Link {
    case connected(TerminalHostConnection, TerminalHostIdentity)
    /// It proved it is ours and will not serve this copy now, or did not answer in time.
    case unavailable(String)
    /// It could not prove it is ours.
    case refused(String)
    case absent
  }

  private let configuration: Configuration
  private let local: PTYTerminalSupervisor
  private var connection: TerminalHostConnection?
  private var identity: TerminalHostIdentity?
  /// Set once starting a host has failed, so every later terminal falls back at once rather than
  /// paying the launch timeout again.
  private var isUnavailable = false
  /// Set by `relinquish`: the application is on its way out and nothing may reconnect.
  private var isClosed = false
  /// Set while the host holds agents the user chose to keep and this copy has not taken them back:
  /// only `reconnect` may connect then. Connecting to start a terminal would make this copy the
  /// host's client without the kept sessions, and its next goodbye would stop agents nobody had
  /// seen again.
  private var awaitsReattach = false
  /// The connection under way, which a terminal started meanwhile waits for: a second `hello`
  /// from this copy would be refused as another client, and that terminal run in the application.
  private var connecting: Task<Bool, Never>?
  private var mirrors: [SessionID: HostedTerminalSession] = [:]
  private var pending: [UInt64: CheckedContinuation<TerminalHostMessage.Body?, Never>] = [:]
  private var nextRequest: UInt64 = 1

  public init(configuration: Configuration, local: PTYTerminalSupervisor = PTYTerminalSupervisor())
  {
    self.configuration = configuration
    self.local = local
  }

  // MARK: - TerminalSupervisor

  public func start(_ spec: TerminalSpec, for id: SessionID) async throws -> any TerminalSession {
    if let existing = await session(for: id), await !existing.state().isFinished {
      throw TerminalError.sessionAlreadyRunning(id)
    }
    guard await ensureConnected(launching: true) else {
      return try await startLocally(spec, for: id)
    }

    switch await request(.start(session: id, spec: spec)) {
    case .started(let processIdentifier):
      let mirror = HostedTerminalSession(
        id: id,
        supervisor: self,
        state: .running(processIdentifier: processIdentifier),
        scrollback: spec.scrollback,
        needsRedraw: false
      )
      mirrors[id] = mirror
      await attach(mirror)
      return mirror
    case .startFailed(let error):
      throw error
    default:
      guard connection != nil else {
        // The host went away between the connection and the start. The terminal is started
        // here, rather than failing a launch the user asked for over a helper they never see.
        return try await startLocally(spec, for: id)
      }
      // No answer in time, from a host that is still there: it may well have started the agent.
      // A second one started here would work in the same folder, so the first is stopped and the
      // launch fails instead.
      send(.kill(session: id))
      throw TerminalError.spawnFailed(code: ETIMEDOUT)
    }
  }

  /// The mirror of an earlier run of this session in the host would stand in front of the local
  /// terminal: `session(for:)` and `stop(id:)` would find it, finished, and never reach the process.
  private func startLocally(_ spec: TerminalSpec, for id: SessionID) async throws
    -> any TerminalSession
  {
    mirrors[id] = nil
    return try await local.start(spec, for: id)
  }

  public func session(for id: SessionID) async -> (any TerminalSession)? {
    if let mirror = mirrors[id] { return mirror }
    return await local.session(for: id)
  }

  public func stop(id: SessionID, gracePeriod: Duration) async {
    if let mirror = mirrors[id] {
      await mirror.stop(gracePeriod: gracePeriod)
      return
    }
    await local.stop(id: id, gracePeriod: gracePeriod)
  }

  public func stopAll(gracePeriod: Duration) async {
    let hosted = Array(mirrors.values)
    await withTaskGroup(of: Void.self) { group in
      for mirror in hosted {
        group.addTask { await mirror.stop(gracePeriod: gracePeriod) }
      }
      group.addTask { await self.local.stopAll(gracePeriod: gracePeriod) }
    }
  }

  // MARK: - TerminalHosting

  public func reconnect() async -> TerminalHostStatus {
    let host: TerminalHostIdentity
    // A host still busy with the previous client — one that crashed a moment ago, whose closed
    // socket it has not read yet — is asked again a few times before the answer is taken.
    var found = await link(launching: false)
    for _ in 0..<5 {
      guard case .unavailable = found else { break }
      try? await Task.sleep(for: .milliseconds(200))
      found = await link(launching: false)
    }
    switch found {
    case .absent:
      awaitsReattach = false
      return .absent
    case .unavailable(let reason):
      awaitsReattach = true
      return .unavailable(reason: reason)
    case .refused(let reason):
      awaitsReattach = false
      return .refused(reason: reason)
    case .connected(let connection, let identity):
      adopt(connection, identity)
      host = identity
    }

    // A host that answered and then did not list its sessions is still there, and so are they:
    // saying it is absent would have them looked for as leftovers, and killed. It has taken this
    // copy as its client, and is left with a goodbye: a silent close reads as a crash, which
    // stops everything.
    guard case .sessions(let records) = await request(.list) else {
      await stepAway()
      return .unavailable(reason: "The terminal host did not list its sessions.")
    }
    awaitsReattach = false
    var summaries: [HostedSessionSummary] = []
    for record in records {
      let mirror = HostedTerminalSession(
        id: record.session,
        supervisor: self,
        state: record.state,
        scrollback: .default,
        needsRedraw: !record.state.isFinished
      )
      mirrors[record.session] = mirror
      await attach(mirror)
      summaries.append(
        HostedSessionSummary(id: record.session, state: record.state, endedAt: record.endedAt))
    }
    return .connected(host, sessions: summaries)
  }

  public func lastStopRequest() -> Date? {
    configuration.location.lastStopRequest()
  }

  public func hostIdentity() -> TerminalHostIdentity? {
    connection == nil ? nil : identity
  }

  public func discard(_ id: SessionID) async {
    guard let mirror = mirrors.removeValue(forKey: id) else { return }
    await mirror.stop(gracePeriod: .seconds(3))
    _ = await request(.release(session: id))
  }

  public func stepAway() async {
    awaitsReattach = true
    // Only what `reconnect` took: nothing is started before the launch has decided.
    mirrors.removeAll()
    guard let connection else { return }
    _ = await request(.goodbye(keepRunning: true), timeout: .seconds(1))
    self.connection = nil
    await connection.closeAfterPendingWrites()
  }

  public func relinquish(keepRunning: Bool) async {
    isClosed = true
    guard let connection else { return }
    // Short: this is said on the way out, under the application's own deadline, and the host acts
    // on the frame, not on whether its acknowledgement made it back.
    _ = await request(.goodbye(keepRunning: keepRunning), timeout: .seconds(1))
    self.connection = nil
    // After the goodbye has left, and not merely been queued: the application exits right after.
    await connection.closeAfterPendingWrites()
  }

  /// Closes the connection without a word, the way a crash of the application does.
  func dropConnection() {
    connection?.close()
  }

  // MARK: - Used by the mirrors

  func send(_ body: TerminalHostRequest.Body) {
    guard let connection else { return }
    connection.send(.control(TerminalHostRequest(request: 0, body: body)))
  }

  func sendInput(_ bytes: [UInt8], to id: SessionID) {
    guard let connection else { return }
    for frame in TerminalHostFrame.terminalChunks(.input, session: id, bytes: bytes) {
      connection.send(frame)
    }
  }

  /// Sends a request and waits for its reply; `nil` when the host is gone or never answered.
  func request(
    _ body: TerminalHostRequest.Body,
    timeout: Duration? = nil
  ) async -> TerminalHostMessage.Body? {
    guard let connection else { return nil }
    let number = nextRequest
    nextRequest += 1
    let deadline = timeout ?? configuration.replyTimeout
    let timer = Task { [weak self] in
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled else { return }
      await self?.resolve(number, with: nil)
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { continuation in
      pending[number] = continuation
      connection.send(.control(TerminalHostRequest(request: number, body: body)))
    }
  }

  // MARK: - The connection

  private func ensureConnected(launching: Bool) async -> Bool {
    if connection != nil { return true }
    guard !isUnavailable, !isClosed, !awaitsReattach else { return false }
    if let connecting { return await connecting.value }
    let attempt = Task { await self.connect(launching: launching) }
    connecting = attempt
    defer { connecting = nil }
    return await attempt.value
  }

  private func connect(launching: Bool) async -> Bool {
    // Twice: a host on its way out, idle, can take the connection and leave with it, and giving
    // up on the first attempt would keep every terminal of this run in the application.
    for _ in 0..<2 {
      if case .connected(let connection, let identity) = await link(launching: launching) {
        adopt(connection, identity)
        return true
      }
    }
    if launching { isUnavailable = true }
    return false
  }

  private func link(launching: Bool) async -> Link {
    guard !isClosed else { return .absent }
    let path = configuration.location.socketPath
    var descriptor = UnixSocket.connect(to: path)
    if descriptor == nil, launching, let launcher = configuration.launcher {
      guard (try? launcher.launch(at: configuration.location)) != nil else { return .absent }
      let deadline = ContinuousClock.now + configuration.launchTimeout
      while descriptor == nil, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        descriptor = UnixSocket.connect(to: path)
      }
    }
    guard let descriptor else { return .absent }

    // Verified before a single byte is sent: the first request carries nothing, but the next ones
    // carry keystrokes and an agent's environment.
    guard configuration.verifier.accepts(peerOf: descriptor) else {
      close(descriptor)
      return .refused("The terminal host could not prove it belongs to this application.")
    }
    let connection = TerminalHostConnection(descriptor: descriptor)
    connection.send(
      .control(
        TerminalHostRequest(
          request: 0,
          body: .hello(
            protocolVersion: TerminalHostWire.protocolVersion,
            build: TerminalHostServer.currentBuild,
            capabilities: [])
        )))

    let reply = await firstMessage(on: connection)
    switch reply?.body {
    case .welcome(let version, _, _, let processIdentifier, let startedAt)
    where version == TerminalHostWire.protocolVersion:
      return .connected(
        connection,
        TerminalHostIdentity(processIdentifier: processIdentifier, processStartedAt: startedAt)
      )
    case .refused(let reason, _):
      connection.close()
      return .unavailable(reason)
    default:
      connection.close()
      return .unavailable("The terminal host did not answer.")
    }
  }

  /// The handshake is read before the connection is handed to the loop that serves it.
  private func firstMessage(on connection: TerminalHostConnection) async -> TerminalHostMessage? {
    let timeout = configuration.replyTimeout
    return await withTaskGroup(of: TerminalHostMessage?.self) { group in
      group.addTask {
        var iterator = connection.frames.makeAsyncIterator()
        return await iterator.next()?.decode(TerminalHostMessage.self)
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if first == nil {
        // The host may still read the `hello` and take this copy as its client. Behind it on the
        // wire, the goodbye lets that client go with the agents running, rather than as a crash
        // that stops them all.
        connection.send(
          .control(TerminalHostRequest(request: 0, body: .goodbye(keepRunning: true))))
        await connection.closeAfterPendingWrites()
      }
      return first
    }
  }

  private func adopt(_ connection: TerminalHostConnection, _ identity: TerminalHostIdentity) {
    self.connection = connection
    self.identity = identity
    Task { [weak self] in
      for await frame in connection.frames {
        await self?.receive(frame)
      }
      await self?.connectionEnded(connection)
    }
  }

  private func attach(_ mirror: HostedTerminalSession) async {
    let reply = await request(.attach(session: mirror.id))
    guard case .attached = reply else {
      await mirror.connectionLost()
      return
    }
  }

  private func receive(_ frame: TerminalHostFrame) async {
    switch frame.kind {
    case .output:
      guard let (id, bytes) = frame.terminalBytes else { return }
      await mirrors[id]?.receive(output: bytes)
    case .input:
      return
    case .control:
      guard let message = frame.decode(TerminalHostMessage.self) else { return }
      await route(message)
    }
  }

  private func route(_ message: TerminalHostMessage) async {
    switch message.body {
    case .attached(let id, let state, let dropped):
      await mirrors[id]?.receiveAttached(state: state, droppedByteCount: dropped)
      if state.isFinished { release(id) }
    case .state(let id, let state, _):
      await mirrors[id]?.receive(state: state)
      if state.isFinished { release(id) }
    case .truncated(let id, let count):
      await mirrors[id]?.receive(truncated: count)
    default:
      break
    }
    if let number = message.request, number != 0 {
      resolve(number, with: message.body)
    }
  }

  /// A session that has ended is read, and the host has no reason to keep it any longer. The
  /// mirror stays: it is what the pane shows, and the last output with it.
  private func release(_ id: SessionID) {
    // A client on its way out has not shown that output to anybody: the session is left for the
    // next launch to read, as one that ended while nobody was attached.
    guard !isClosed else { return }
    send(.release(session: id))
  }

  private func resolve(_ number: UInt64, with body: TerminalHostMessage.Body?) {
    pending.removeValue(forKey: number)?.resume(returning: body)
  }

  private func connectionEnded(_ ended: TerminalHostConnection) async {
    guard connection === ended else { return }
    connection = nil
    for continuation in pending.values {
      continuation.resume(returning: nil)
    }
    pending.removeAll()
    for mirror in mirrors.values {
      await mirror.connectionLost()
    }
  }
}
