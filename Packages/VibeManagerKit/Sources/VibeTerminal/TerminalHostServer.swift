import Darwin
import Foundation
import VibeApplication
import VibeDomain
import VibeProcess

/// The terminal host's side of the wire: the sessions it runs, and the one client it serves.
///
/// Every terminal is a `PTYTerminalSession`, exactly as it was in the application (ADR 0004): the
/// host adds a socket in front of them, and three rules about who may leave them running.
///
/// 1. **One client at a time.** A second copy of the application is refused rather than served:
///    it would read and type into terminals another copy is showing.
/// 2. **Left running only when asked.** A client that goes away without `goodbye(keepRunning:)`
///    has crashed or been killed, and everything is stopped, as the death of the application has
///    always stopped its agents. Its output may be what brought the application down; replaying it
///    into the next launch unasked would bring that one down too.
/// 3. **Gone when idle.** With no session and no client for a grace period, the host ends. A
///    session that ended while nobody was attached counts as a session until a client has read its
///    last output and released it.
public actor TerminalHostServer {
  public struct Configuration: Sendable {
    public var verifier: any TerminalHostPeerVerifier
    public var idleGracePeriod: Duration
    /// How long a session that ended with nobody attached waits to be read.
    public var endedRetention: Duration
    public var build: String
    /// Sessions running at once. Each holds a terminal and a handful of descriptors: past this, the
    /// host would run out of them in the middle of serving the others rather than refuse one.
    public var maximumRunningSessions: Int
    /// The host's own log, `host.jsonl`, keyed by the same salt as the application's.
    public var diagnostics: Diagnostics

    public init(
      verifier: any TerminalHostPeerVerifier,
      idleGracePeriod: Duration = .seconds(5),
      endedRetention: Duration = .seconds(24 * 60 * 60),
      build: String = TerminalHostServer.currentBuild,
      maximumRunningSessions: Int = TerminalHostServer.defaultMaximumRunningSessions,
      diagnostics: Diagnostics = .disabled
    ) {
      self.diagnostics = diagnostics
      self.verifier = verifier
      self.idleGracePeriod = idleGracePeriod
      self.endedRetention = endedRetention
      self.build = build
      self.maximumRunningSessions = maximumRunningSessions
    }
  }

  public static let defaultMaximumRunningSessions = 64

  public static var currentBuild: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    return "\(version) (\(build))"
  }

  private struct Hosted {
    let session: PTYTerminalSession
    var endedAt: Date?
  }

  private final class Client: Sendable {
    let connection: TerminalHostConnection
    let identifier = UUID()

    init(connection: TerminalHostConnection) {
      self.connection = connection
    }
  }

  private let configuration: Configuration
  private let onIdle: @Sendable () -> Void
  private var sessions: [SessionID: Hosted] = [:]
  private var owner: Client?
  private var keepsRunning = false
  private var forwards: [SessionID: Task<Void, Never>] = [:]
  private var idleTask: Task<Void, Never>?
  /// Held while a session runs: App Nap and timer coalescing must not slow the reading of a
  /// terminal an agent is writing to. The Mac may still go to sleep, as it could before.
  private var activity: (any NSObjectProtocol)?
  /// Asked of the kernel, not of the clock: it is what the application confronts, with a
  /// second's tolerance, and the host is a whole application binary that takes a while to reach
  /// this line — longer still the first time the system assesses it.
  private let startedAt = SystemProcessLivenessProbe().startTime(of: getpid())

  public init(configuration: Configuration, onIdle: @escaping @Sendable () -> Void) {
    self.configuration = configuration
    self.onIdle = onIdle
  }

  /// Arms the idle deadline: a host nobody connects to must not stay.
  public func begin() {
    updateIdleState()
  }

  /// Takes a connection freshly accepted on the listening socket.
  public func accept(descriptor: Int32) {
    guard configuration.verifier.accepts(peerOf: descriptor) else {
      configuration.diagnostics.record(.host, .error, "host.peerRefused")
      close(descriptor)
      return
    }
    let client = Client(connection: TerminalHostConnection(descriptor: descriptor))
    Task { await self.serve(client) }
  }

  /// Stops everything and forgets it. What `SIGTERM` does to the host.
  public func stopEverything() async {
    owner?.connection.close()
    owner = nil
    await stopAll()
  }

  public var sessionCount: Int { sessions.count }

  // MARK: - A client

  private func serve(_ client: Client) async {
    var isOwner = false
    for await frame in client.connection.frames {
      if !isOwner {
        guard await handshake(frame, from: client) else { break }
        isOwner = true
        continue
      }
      await handle(frame, from: client)
    }
    client.connection.close()
    if isOwner {
      await disconnected(client)
    }
  }

  /// The first frame has to be a `hello` in a protocol this host speaks, from the only client.
  private func handshake(_ frame: TerminalHostFrame, from client: Client) async -> Bool {
    guard let request = frame.decode(TerminalHostRequest.self),
      case .hello(let version, _, _) = request.body
    else { return false }

    if version != TerminalHostWire.protocolVersion {
      configuration.diagnostics.record(
        .host, .notice, "host.clientRefused",
        ["reason": .token(DiagnosticToken("incompatible")), "protocol": .code(Int32(version))])
      let reason = "This terminal host speaks protocol \(TerminalHostWire.protocolVersion)."
      await reply(request.request, .refused(reason: reason, refusal: .incompatible), to: client)
      return false
    }
    if owner != nil {
      configuration.diagnostics.record(
        .host, .notice, "host.clientRefused", ["reason": .token(DiagnosticToken("otherClient"))])
      let reason = "Another copy of Vibe Manager is attached to this terminal host."
      await reply(request.request, .refused(reason: reason, refusal: .otherClient), to: client)
      return false
    }

    owner = client
    keepsRunning = false
    configuration.diagnostics.record(
      .host, .info, "host.clientAttached", ["sessions": .count(sessions.count)])
    updateIdleState()
    await reply(
      request.request,
      .welcome(
        protocolVersion: TerminalHostWire.protocolVersion,
        build: configuration.build,
        capabilities: TerminalHostCapability.all,
        processIdentifier: getpid(),
        startedAt: startedAt
      ),
      to: client
    )
    return true
  }

  private func handle(_ frame: TerminalHostFrame, from client: Client) async {
    switch frame.kind {
    case .input:
      guard let (id, bytes) = frame.terminalBytes, let hosted = sessions[id] else { return }
      await hosted.session.write(bytes)
    case .output:
      // Nothing a client sends is output.
      return
    case .control:
      guard let request = frame.decode(TerminalHostRequest.self) else { return }
      await handle(request, from: client)
    }
  }

  private func handle(_ request: TerminalHostRequest, from client: Client) async {
    let number = request.request
    switch request.body {
    case .hello:
      await reply(number, .refused(reason: "Already attached.", refusal: .otherClient), to: client)
    case .list:
      await reply(number, .sessions(records()), to: client)
    case .start(let id, let spec):
      await reply(number, start(spec, for: id), to: client)
    case .attach(let id):
      await attach(id, request: number, client: client)
    case .resize(let id, let size):
      await sessions[id]?.session.resize(to: size)
    case .redraw(let id):
      await sessions[id]?.session.redraw()
    case .stop(let id, let milliseconds):
      guard let session = sessions[id]?.session else {
        return await reply(number, .unknownSession, to: client)
      }
      // Off the client's loop: a grace period paid here would hold every keystroke behind it.
      Task {
        await session.stop(gracePeriod: .milliseconds(milliseconds))
        await self.replyStopped(number, session: session, to: client)
      }
    case .kill(let id):
      guard let session = sessions[id]?.session else {
        return await reply(number, .unknownSession, to: client)
      }
      Task {
        await session.kill()
        await self.replyStopped(number, session: session, to: client)
      }
    case .release(let id):
      await release(id)
      await reply(number, .done, to: client)
    case .stats:
      await reply(
        number,
        .stats(footprintBytes: ProcessMetrics.physicalFootprint() ?? 0, sessions: sessions.count),
        to: client)
    case .goodbye(let keepRunning):
      keepsRunning = keepRunning
      await reply(number, .done, to: client)
      // The place is free as soon as it is said, not once the socket is seen closed: an
      // application relaunched at once must not find its own previous run still attached.
      await disconnected(client)
    }
  }

  /// `stopped` leaves after the last of the session's own output and its final state, never
  /// before: the client ends its stream on the reply, and whatever came after it would be lost —
  /// or, worse, reach the next process started under the same session.
  private func replyStopped(
    _ number: UInt64,
    session: PTYTerminalSession,
    to client: Client
  ) async {
    await forwards[session.id]?.value
    await reply(number, .stopped(state: await session.state()), to: client)
  }

  private func records() async -> [HostedSessionRecord] {
    var records: [HostedSessionRecord] = []
    for (id, hosted) in sessions {
      records.append(
        HostedSessionRecord(
          session: id, state: await hosted.session.state(), endedAt: hosted.endedAt))
    }
    return records
  }

  private func start(_ spec: TerminalSpec, for id: SessionID) async -> TerminalHostMessage.Body {
    if let existing = sessions[id] {
      guard await existing.session.state().isFinished else {
        return .startFailed(.sessionAlreadyRunning(id))
      }
      await release(id)
    }
    var running = 0
    for hosted in sessions.values where await !hosted.session.state().isFinished {
      running += 1
    }
    guard running < configuration.maximumRunningSessions else {
      configuration.diagnostics.record(
        .host, .error, "host.startRefused",
        ["session": configuration.diagnostics.pseudonym(id), "running": .count(running)])
      return .startFailed(.tooManySessions(limit: configuration.maximumRunningSessions))
    }
    do {
      let session = try PTYTerminalSession.start(id: id, spec: spec)
      configuration.diagnostics.record(
        .session, .info, "host.sessionStarted",
        ["session": configuration.diagnostics.pseudonym(id), "running": .count(running + 1)])
      sessions[id] = Hosted(session: session)
      watch(session)
      updateIdleState()
      guard case .running(let processIdentifier) = await session.state() else {
        return .started(processIdentifier: 0)
      }
      return .started(processIdentifier: processIdentifier)
    } catch let error as TerminalError {
      var fields: [(name: StaticString, value: DiagnosticValue)] = [
        ("session", configuration.diagnostics.pseudonym(id)),
        ("error", .token(error.diagnosticToken)),
      ]
      if let code = error.diagnosticCode { fields.append(("errorCode", .code(code))) }
      configuration.diagnostics.log.record(
        DiagnosticEvent(.session, .error, "host.startFailed", fields: fields))
      return .startFailed(error)
    } catch {
      return .startFailed(.spawnFailed(code: 0))
    }
  }

  /// History first, then `attached`, then the live stream — one consistent value, as
  /// `TerminalSession.attach()` promises, cut into frames.
  private func attach(_ id: SessionID, request: UInt64, client: Client) async {
    guard let hosted = sessions[id] else {
      return await reply(request, .unknownSession, to: client)
    }
    forwards.removeValue(forKey: id)?.cancel()
    let attachment = await hosted.session.attach()
    let history = attachment.history.bytes
    var offset = 0
    while offset < history.count {
      let end = min(offset + TerminalHostWire.historyChunkLength, history.count)
      let frame = TerminalHostFrame.terminal(
        .output, session: id, bytes: Array(history[offset..<end]))
      await client.connection.sendAndWait(frame)
      offset = end
    }
    await reply(
      request,
      .attached(
        session: id,
        state: attachment.state,
        droppedByteCount: attachment.history.droppedByteCount
      ),
      to: client
    )

    let connection = client.connection
    forwards[id] = Task { [weak self] in
      for await event in attachment.events {
        guard !Task.isCancelled else { return }
        switch event {
        case .output(let bytes):
          // Waited for, so a client that stops reading holds this task rather than a queue: the
          // session's own bounded stream then drops its oldest output and says how much.
          for frame in TerminalHostFrame.terminalChunks(.output, session: id, bytes: bytes) {
            await connection.sendAndWait(frame)
          }
        case .historyTruncated(let count):
          await connection.sendAndWait(
            .control(
              TerminalHostMessage(
                request: nil, body: .truncated(session: id, droppedByteCount: count))))
        case .stateChanged(let state):
          let endedAt = await self?.endedAt(of: id)
          await connection.sendAndWait(
            .control(
              TerminalHostMessage(
                request: nil, body: .state(session: id, state: state, endedAt: endedAt))))
        }
      }
    }
  }

  private func endedAt(of id: SessionID) -> Date? {
    sessions[id]?.endedAt
  }

  private func release(_ id: SessionID) async {
    guard let hosted = sessions[id], await hosted.session.state().isFinished else { return }
    sessions[id] = nil
    forwards.removeValue(forKey: id)?.cancel()
    updateIdleState()
  }

  private func disconnected(_ client: Client) async {
    guard owner === client else { return }
    owner = nil
    for task in forwards.values {
      task.cancel()
    }
    forwards.removeAll()
    configuration.diagnostics.record(
      .host, keepsRunning ? .info : .notice, "host.clientDetached",
      ["keepRunning": .flag(keepsRunning), "sessions": .count(sessions.count)])
    if !keepsRunning {
      await stopAll()
    }
    updateIdleState()
  }

  private func stopAll() async {
    let running = sessions.values.map(\.session)
    sessions.removeAll()
    await withTaskGroup(of: Void.self) { group in
      for session in running {
        group.addTask { await session.stop(gracePeriod: .seconds(3)) }
      }
    }
    updateIdleState()
  }

  private func reply(_ request: UInt64, _ body: TerminalHostMessage.Body, to client: Client) async {
    await client.connection.sendAndWait(
      .control(TerminalHostMessage(request: request, body: body)))
  }

  // MARK: - Sessions ending, and the host with them

  /// Notes when a session ends, whoever is attached: the next launch dates its closing from it.
  private func watch(_ session: PTYTerminalSession) {
    Task { [weak self] in
      let attachment = await session.attach()
      // The stream ends once the session has said how it ended, and not before.
      for await _ in attachment.events {}
      await self?.sessionEnded(session)
    }
  }

  private func sessionEnded(_ session: PTYTerminalSession) {
    guard sessions[session.id]?.session === session else { return }
    sessions[session.id]?.endedAt = Date()
    let id = session.id
    let diagnostics = configuration.diagnostics
    Task {
      let state = await session.state()
      var fields: [(name: StaticString, value: DiagnosticValue)] = [
        ("session", diagnostics.pseudonym(id)), ("state", .token(state.diagnosticToken)),
      ]
      fields += state.diagnosticFields
      diagnostics.log.record(DiagnosticEvent(.session, .info, "host.sessionEnded", fields: fields))
    }
    updateIdleState()
    // Kept for the next launch, but not for ever: an application never reopened must not leave a
    // host behind for the rest of the login, holding output nobody will read.
    let retention = configuration.endedRetention
    Task { [weak self] in
      try? await Task.sleep(for: retention)
      await self?.forgetUnread(session)
    }
  }

  private func forgetUnread(_ session: PTYTerminalSession) {
    guard owner == nil, sessions[session.id]?.session === session else { return }
    sessions[session.id] = nil
    updateIdleState()
  }

  private func updateIdleState() {
    Task { await self.refreshActivity() }
    guard sessions.isEmpty, owner == nil else {
      idleTask?.cancel()
      idleTask = nil
      return
    }
    guard idleTask == nil else { return }
    let grace = configuration.idleGracePeriod
    idleTask = Task { [weak self] in
      try? await Task.sleep(for: grace)
      guard !Task.isCancelled else { return }
      await self?.endIfStillIdle()
    }
  }

  private func endIfStillIdle() {
    guard sessions.isEmpty, owner == nil else { return }
    configuration.diagnostics.record(.host, .info, "host.idleExit")
    configuration.diagnostics.flush()
    onIdle()
  }

  private func refreshActivity() async {
    var isRunning = false
    for hosted in sessions.values where hosted.endedAt == nil {
      isRunning = true
      break
    }
    if isRunning, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Coding agents are running in a terminal"
      )
    } else if !isRunning, let current = activity {
      ProcessInfo.processInfo.endActivity(current)
      activity = nil
    }
  }
}
