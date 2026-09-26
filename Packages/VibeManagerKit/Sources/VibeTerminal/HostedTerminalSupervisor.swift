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
public actor HostedTerminalSupervisor: TerminalSupervisor, TerminalHosting, AgentRunnerControl {
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
    public var diagnostics: Diagnostics
    /// Tells a process group that is still ours from one that took its number.
    public var processes: any ProcessLivenessProbe

    public init(
      location: TerminalHostLocation,
      launcher: (any TerminalHostLaunching)?,
      verifier: any TerminalHostPeerVerifier,
      launchTimeout: Duration = .seconds(10),
      replyTimeout: Duration = .seconds(5),
      diagnostics: Diagnostics = .disabled,
      processes: any ProcessLivenessProbe = SystemProcessLivenessProbe()
    ) {
      self.diagnostics = diagnostics
      self.processes = processes
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
  private var diagnostics: Diagnostics { configuration.diagnostics }
  private let local: PTYTerminalSupervisor
  private var connection: TerminalHostConnection?
  private var identity: TerminalHostIdentity?
  /// What the connected host said it speaks beyond the core.
  private var hostCapabilities: Set<String> = []
  /// What the connected host said of its Full Disk Access. It cannot change while the host runs,
  /// so it is asked once per connection.
  private var hostFullDiskAccess: FullDiskAccessStatus?
  /// Set when the host is to be let go as soon as no agent runs there (#76).
  private var restartArmed = false
  /// The host being let go. A terminal started meanwhile waits for it: it must reach the next
  /// host, born with the access, not the one on its way out.
  private var retirement: Task<Void, Never>?
  /// Starts sent to the host and not answered yet.
  private var startsInFlight = 0
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
  /// The process group of each agent the host runs for this copy, and when the kernel says it
  /// started: what is stopped, after checking it is still the same, if the host dies.
  private var groups: [SessionID: (group: Int32, startedAt: Date?)] = [:]
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
    guard await connectedOutsideRetirement() else {
      return try await startLocally(spec, for: id)
    }

    // Counted until its mirror exists: before that, nothing else says an agent is on its way, and
    // a host let go meanwhile would take it with it.
    startsInFlight += 1
    let reply = await request(.start(session: id, spec: spec))
    defer { startsInFlight -= 1 }
    switch reply {
    case .started(let processIdentifier):
      remember(processIdentifier, for: id)
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
    diagnostics.record(
      .host, .notice, "host.fallbackInProcess", ["session": diagnostics.pseudonym(id)])
    mirrors[id] = nil
    groups[id] = nil
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
    let signpost = Signposts.begin("host.attach")
    defer { Signposts.end("host.attach", signpost) }
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
      return .unavailable(
        reason: String(localized: "The terminal host did not list its sessions.", bundle: .module))
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
      if case .running(let processIdentifier) = record.state {
        remember(processIdentifier, for: record.session)
      }
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

  /// The host's physical footprint in bytes, when a host that can say it is connected.
  public func hostFootprint() async -> Int? {
    guard connection != nil, hostCapabilities.contains(TerminalHostCapability.stats),
      case .stats(let bytes, _) = await request(.stats)
    else { return nil }
    return bytes
  }

  /// The host as the export reports it: its identity, and the state of each session it runs for
  /// this copy, by pseudonym. Read from what the host last said, never asked again.
  public func diagnosticReport() async -> DiagnosticSnapshot.Host? {
    guard connection != nil, let identity else { return nil }
    var sessions: [DiagnosticSnapshot.HostSession] = []
    for (id, mirror) in mirrors {
      guard case .session(let pseudonym) = diagnostics.pseudonym(id) else { continue }
      sessions.append(
        DiagnosticSnapshot.HostSession(
          session: pseudonym, state: await mirror.state().diagnosticToken))
    }
    return DiagnosticSnapshot.Host(
      processIdentifier: identity.processIdentifier,
      startedAt: identity.processStartedAt,
      protocolVersion: TerminalHostWire.protocolVersion,
      sessions: sessions.sorted { $0.session.rawValue < $1.session.rawValue })
  }

  public func discard(_ id: SessionID) async {
    groups[id] = nil
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

  /// Closes the connection without a word, the way a crash of the application does — and, like
  /// a crash, does nothing about it on this side: what happens next is the host's to decide.
  func dropConnection() {
    let dropped = connection
    connection = nil
    dropped?.close()
  }

  /// Connected to a host that is not on its way out. Checked again after every suspension, so the
  /// `start` that follows leaves in the same turn of the actor: either before a `retire` — which the
  /// host then refuses, an agent running — or once the next host is there. Reaching a host that is
  /// leaving would read as one that will not serve, and send every later terminal into the
  /// application.
  private func connectedOutsideRetirement() async -> Bool {
    while true {
      while let retirement { await retirement.value }
      let connected = await ensureConnected(launching: true)
      if retirement == nil { return connected }
    }
  }

  // MARK: - AgentRunnerControl

  public func agentRunnerAccess() async -> AgentRunnerAccess {
    if connection != nil {
      return AgentRunnerAccess(
        runner: .host, hostStatus: await hostAccess(),
        runningAgents: await runningHostedSessions().count)
    }
    // The next terminal starts here — the host could not be used, is turned off, or keeps agents
    // this copy has not taken back — or one already runs here: the application answers for them.
    let runningHere = await local.runningCount()
    if isUnavailable || isClosed || awaitsReattach || configuration.launcher == nil
      || runningHere > 0
    {
      return AgentRunnerAccess(runner: .application, runningAgents: runningHere)
    }
    return .none
  }

  public func runningHostedSessions() async -> [SessionID] {
    var running: [SessionID] = []
    for (id, mirror) in mirrors where await !mirror.state().isFinished {
      running.append(id)
    }
    return running
  }

  public func restartHostWhenIdle() async -> HostRestart {
    guard connection != nil else {
      restartArmed = false
      return .restarted
    }
    restartArmed = true
    await restartIfIdle()
    return restartArmed ? .armed : .restarted
  }

  public func cancelHostRestart() {
    restartArmed = false
  }

  public func isHostRestartArmed() -> Bool {
    restartArmed
  }

  /// Whether the host has Full Disk Access, `nil` when it cannot say.
  private func hostAccess() async -> FullDiskAccessStatus? {
    if let hostFullDiskAccess { return hostFullDiskAccess }
    guard hostCapabilities.contains(TerminalHostCapability.fullDiskAccess),
      case .fullDiskAccess(let granted) = await request(.fullDiskAccess)
    else { return nil }
    let status: FullDiskAccessStatus = granted ? .granted : .notGranted
    hostFullDiskAccess = status
    return status
  }

  /// Lets the host go when it is armed to and no agent runs there any more.
  ///
  /// The retirement is claimed before anything is awaited: two sessions ending together each ask,
  /// and a start arriving meanwhile must find it claimed rather than race it.
  private func restartIfIdle() async {
    guard restartArmed, connection != nil else { return }
    if let retirement { return await retirement.value }
    let task = Task { await self.retireIfIdle() }
    retirement = task
    await task.value
    retirement = nil
  }

  private func retireIfIdle() async {
    guard startsInFlight == 0, await runningHostedSessions().isEmpty else { return }
    await retire()
  }

  /// Says goodbye to an idle host and waits for it to be gone, so the next terminal starts a host
  /// of its own. The mirrors stay: they are what the panes show of the sessions that ended.
  private func retire() async {
    guard let old = connection else { return }
    if hostCapabilities.contains(TerminalHostCapability.retire) {
      // Refused when an agent was started in the host meanwhile: it restarts after that one.
      guard case .retiring(accepted: true) = await request(.retire) else { return }
    }
    restartArmed = false
    let hostProcess = identity?.processIdentifier
    diagnostics.record(.host, .notice, "host.retired", ["sessions": .count(mirrors.count)])
    _ = await request(.goodbye(keepRunning: false), timeout: .seconds(1))
    connection = nil
    identity = nil
    hostCapabilities = []
    hostFullDiskAccess = nil
    groups.removeAll()
    await old.closeAfterPendingWrites()
    // A host that can retire leaves at once; an older one after its idle grace period. Either way
    // its socket goes with it, and until then a new terminal would reach it again.
    let deadline = ContinuousClock.now + .seconds(8)
    while FileManager.default.fileExists(atPath: configuration.location.socketPath),
      hostProcess.map({ kill($0, 0) == 0 }) ?? true,
      ContinuousClock.now < deadline
    {
      try? await Task.sleep(for: .milliseconds(20))
    }
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
      let launchedAt = ContinuousClock.now
      do {
        try launcher.launch(at: configuration.location)
      } catch {
        var fields: [(name: StaticString, value: DiagnosticValue)] = []
        if let code = DiagnosticValue.posixCode(of: error) { fields.append(("errno", code)) }
        diagnostics.log.record(DiagnosticEvent(.host, .error, "host.launchFailed", fields: fields))
        return .absent
      }
      let deadline = ContinuousClock.now + configuration.launchTimeout
      while descriptor == nil, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        descriptor = UnixSocket.connect(to: path)
      }
      diagnostics.record(
        .host, descriptor == nil ? .error : .info, "host.launched",
        ["listening": .flag(descriptor != nil), "duration": .duration(.now - launchedAt)])
    }
    guard let descriptor else { return .absent }

    // Verified before a single byte is sent: the first request carries nothing, but the next ones
    // carry keystrokes and an agent's environment.
    guard configuration.verifier.accepts(peerOf: descriptor) else {
      close(descriptor)
      diagnostics.record(.host, .error, "host.verifyFailed")
      return .refused(
        String(
          localized: "The terminal host could not prove it belongs to this application.",
          bundle: .module))
    }
    let connection = TerminalHostConnection(descriptor: descriptor)
    connection.send(
      .control(
        TerminalHostRequest(
          request: 0,
          body: .hello(
            protocolVersion: TerminalHostWire.protocolVersion,
            build: TerminalHostServer.currentBuild,
            capabilities: TerminalHostCapability.all)
        )))

    let reply = await firstMessage(on: connection)
    switch reply?.body {
    case .welcome(let version, _, let capabilities, let processIdentifier, let startedAt)
    where version == TerminalHostWire.protocolVersion:
      hostCapabilities = Set(capabilities)
      diagnostics.record(
        .host, .info, "host.connected",
        [
          "protocol": .code(Int32(version)),
          "stats": .flag(capabilities.contains(TerminalHostCapability.stats)),
        ])
      return .connected(
        connection,
        TerminalHostIdentity(processIdentifier: processIdentifier, processStartedAt: startedAt)
      )
    case .refused(let reason, let refusal):
      connection.close()
      diagnostics.record(
        .host, .notice, "host.unavailable",
        ["reason": .token(refusal == .otherClient ? "otherClient" : "incompatible")])
      return .unavailable(reason)
    default:
      connection.close()
      diagnostics.record(.host, .notice, "host.unavailable", ["reason": .token("noAnswer")])
      return .unavailable(String(localized: "The terminal host did not answer.", bundle: .module))
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
    hostFullDiskAccess = nil
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
      noteGroup(of: state, for: id)
      await mirrors[id]?.receiveAttached(state: state, droppedByteCount: dropped)
      if state.isFinished { release(id) }
    case .state(let id, let state, _):
      noteGroup(of: state, for: id)
      await mirrors[id]?.receive(state: state)
      if state.isFinished {
        release(id)
        // Not awaited: this runs on the loop that reads the host's replies, and letting the host
        // go asks it something first.
        if restartArmed { Task { await self.restartIfIdle() } }
      }
    case .truncated(let id, let count):
      diagnostics.record(
        .host, .notice, "host.outputTruncated",
        ["session": diagnostics.pseudonym(id), "bytes": .bytes(count)])
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

  /// A start the host answered before its process was running says so with a pid of 0: the group
  /// is learnt from the state that follows.
  private func noteGroup(of state: TerminalProcessState, for id: SessionID) {
    guard mirrors[id] != nil else { return }
    switch state {
    case .running(let processIdentifier) where groups[id]?.group != processIdentifier:
      remember(processIdentifier, for: id)
    case .exited, .terminated, .failed:
      groups[id] = nil
    case .starting, .running:
      break
    }
  }

  private func remember(_ processIdentifier: Int32, for id: SessionID) {
    guard processIdentifier > 0 else { return }
    groups[id] = (processIdentifier, configuration.processes.startTime(of: processIdentifier))
  }

  /// The host closed the connection without a `done`: it crashed, or was killed. Its terminals
  /// closed with it and sent their groups a hang-up, but an agent that ignores it would run on,
  /// with no terminal and nobody to see it, until the next launch found it. Every group the host
  /// ran for this copy is stopped now, once it is shown to still be ours (ADR 0011's rule: the
  /// group and the instant it started), and its session ends saying why. A session whose group
  /// was not recorded, or could not be shown to be ours, is not said to be stopped: whatever it
  /// ran may still be running, and it ends as one whose outcome is unknown.
  private func connectionEnded(_ ended: TerminalHostConnection) async {
    guard connection === ended else { return }
    connection = nil
    for continuation in pending.values {
      continuation.resume(returning: nil)
    }
    pending.removeAll()
    var stopped = 0
    for (id, mirror) in mirrors {
      guard await !mirror.state().isFinished else { continue }
      let outcome = groups[id].map { stopGroup($0.group, startedAt: $0.startedAt, for: id) }
      switch outcome {
      case .stopped:
        stopped += 1
        await mirror.hostStopped()
      case .alreadyGone:
        await mirror.hostStopped()
      case .unreachable, nil:
        await mirror.connectionLost()
      }
    }
    groups.removeAll()
    diagnostics.record(
      .host, .error, "host.connectionLost",
      ["sessions": .count(mirrors.count), "stopped": .count(stopped)])
  }

  private enum GroupOutcome {
    /// Killed now.
    case stopped
    /// Its leader and every member had already exited: the hang-up of the terminal was enough.
    case alreadyGone
    /// Not shown to be ours, or the kill failed: it may still be running.
    case unreachable
  }

  /// `SIGKILL` to a group, when it is the one this copy recorded. A group whose leader has exited
  /// is still ours while it has members: the kernel gives no process a pid that names a live group.
  private func stopGroup(_ group: Int32, startedAt: Date?, for id: SessionID) -> GroupOutcome {
    let identity = configuration.processes.identify(processGroup: group, startedAt: startedAt)
    let outcome: GroupOutcome
    switch identity {
    case .matches:
      outcome = configuration.processes.terminate(processGroup: group) ? .stopped : .unreachable
    case .gone where kill(-group, 0) != 0 && errno == ESRCH:
      outcome = .alreadyGone
    case .gone:
      outcome = configuration.processes.terminate(processGroup: group) ? .stopped : .unreachable
    case .differs, .unknown:
      outcome = .unreachable
    }
    let stopped = outcome == .stopped
    let token: DiagnosticToken
    switch identity {
    case .matches: token = "matches"
    case .gone: token = "gone"
    case .differs: token = "differs"
    case .unknown: token = "unknown"
    }
    diagnostics.record(
      .host, .notice, "host.agentStopped",
      [
        "session": diagnostics.pseudonym(id), "identity": .token(token),
        "stopped": .flag(stopped), "errno": .code(stopped ? 0 : errno),
      ])
    return outcome
  }
}
