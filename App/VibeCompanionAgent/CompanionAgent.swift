import AppKit
import CompanionCore
import CompanionKit
import CompanionWire
import SystemConfiguration
import os

/// The Mac's side of the mobile companion (#347), in a process of its own.
///
/// It holds the iCloud entitlement the application must not (ADR 0021) and runs the Mac's only
/// `CKSyncEngine`. It knows nothing of sessions: it writes what the application hands it over the
/// link, and hands back the tests it finds. When the link closes — the application quit or
/// crashed — it writes the Mac offline and quits too.
@MainActor
final class CompanionAgent {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "agent")
  private static let notifyLogger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "notify")
  /// The application is the only peer: the same team, its identifier.
  private static let applicationIdentifier = "eu.hadrien.VibeManager"
  /// How often the zone is asked directly, pushes or not: CloudKit's are silent ones, which the
  /// system delays and drops past a few an hour, and a test must not wait for them. A fetch with
  /// nothing new is one request, and pushes nothing to anyone.
  private static let pollInterval: TimeInterval = 5
  /// How long a departing agent waits for its last write to leave.
  private static let departureLimit: TimeInterval = 10

  struct Arguments {
    let socketPath: String
    let stateDirectory: URL

    init?(_ arguments: [String]) {
      func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
          return nil
        }
        return arguments[index + 1]
      }
      guard let socketPath = value(after: "--link"), let state = value(after: "--state"),
        state.hasPrefix("/")
      else { return nil }
      self.socketPath = socketPath
      stateDirectory = URL(fileURLWithPath: state, isDirectory: true)
    }
  }

  /// What the application said of itself.
  private struct Installation {
    let id: String
    let version: String
    let buildLabel: String
  }

  let sync: CompanionCloudSync
  /// The active channel's end (#368), and the address it is reached at, once bound.
  private let echo: CompanionEchoServer
  private var irohAddress: CompanionEchoServer.Address?
  private let arguments: Arguments
  private var connection: CompanionLinkConnection?
  private var installation: Installation?
  private var records: [CompanionRecord] = []
  private var snapshot: [CompanionSessionInfo]?
  /// The tests handed to the application, so that a record fetched twice raises one alert.
  private var handled: Set<String> = []
  /// The answers handed to the application (#401), so that an answer fetched twice is given once.
  private var givenAnswers: Set<String> = []
  private var timers: [Timer] = []
  private var isDeparting = false
  private var isPolling = false
  /// Keeps App Nap away: a process without a window is its first candidate, and a napping agent's
  /// heartbeat could come later than the phone's tolerance. The Mac may still sleep.
  private var activity: (any NSObjectProtocol)?

  init(arguments: Arguments) {
    self.arguments = arguments
    sync = CompanionCloudSync(
      storeURL: arguments.stateDirectory.appendingPathComponent("sync.json", isDirectory: false))
    echo = CompanionEchoServer(stateDirectory: arguments.stateDirectory)
  }

  func start() async {
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "The mobile companion's presence and tests")
    await sync.start { [weak self] update in
      Task { @MainActor in self?.apply(update) }
    }
    guard connect() else {
      Self.logger.error("no application to talk to: quitting")
      await quit()
      return
    }
    schedule()
    let echo = self.echo
    Task { [weak self] in
      await echo.start(
        authorize: { [weak self] endpointID in await self?.isPaired(endpointID) ?? false },
        onRemote: { [weak self] event in
          Task { @MainActor in self?.relay(event) }
        },
        onAddress: { [weak self] address in
          Task { @MainActor in await self?.irohAddressChanged(address) }
        })
    }
    await sync.fetchChanges()
  }

  /// Written in the `Mac` record at once: the phone dials what it reads there. The relay changes
  /// rarely, the identifier never, so this is no frequent write.
  private func irohAddressChanged(_ address: CompanionEchoServer.Address) async {
    guard address != irohAddress, !isDeparting else { return }
    irohAddress = address
    reportStatus(signedIn: sentStatus?.signedIn ?? false)
    CompanionIroh.logger.notice(
      "echo: publishing \(address.endpointID, privacy: .public) via \(address.relayURL ?? "no relay", privacy: .public)"
    )
    await writeMac(online: true)
    sendSoon()
  }

  // MARK: - Link

  private func connect() -> Bool {
    guard let descriptor = CompanionSocket.connect(to: arguments.socketPath) else { return false }
    guard
      CodeSigningCompanionPeerVerifier(peerIdentifier: Self.applicationIdentifier)
        .accepts(peerOf: descriptor)
    else {
      Self.logger.error("the peer is not Vibe Manager: refused")
      close(descriptor)
      return false
    }
    let connection = CompanionLinkConnection(descriptor: descriptor)
    self.connection = connection
    connection.send(.welcome(protocolVersion: CompanionLinkWire.protocolVersion))
    Task {
      for await message in connection.messages {
        self.handle(message)
      }
      await self.linkClosed()
    }
    return true
  }

  /// Takes each message at once, never waiting for iCloud: the loop that reads them used to await
  /// a send in `hello`, and every message behind it — sessions, acknowledgements — waited with it
  /// (the trial of #347: a Mac online, without a session or a pong). The work runs in tasks of its
  /// own, in the order the messages came, on the main actor.
  private func handle(_ message: CompanionLinkMessage) {
    switch message {
    case .hello(_, let id, let version, let buildLabel):
      Self.logger.notice(
        "link: hello from \(id, privacy: .public), \(buildLabel, privacy: .public)")
      installation = Installation(id: id, version: version, buildLabel: buildLabel)
      sentStatus = nil
      sentDevices = nil
      reportDevices()
      Task {
        await sync.note("application connectée (\(buildLabel.isEmpty ? version : buildLabel))")
        await writeMac(online: true)
        await mergeSessions()
        await purgeRequests()
        sendSoon()
      }
      answerTests()
      giveAnswers()
    case .snapshot(let sessions):
      Self.logger.notice("link: snapshot of \(sessions.count, privacy: .public) session(s)")
      let entered = CompanionRequests.entered(previous: snapshot, current: sessions)
      snapshot = sessions
      Task {
        await mergeSessions()
        await writeRequests(for: entered)
        sendSoon()
      }
    case .testAcknowledged(let nonce, let receivedAt):
      Self.logger.notice("link: test \(nonce, privacy: .public) acknowledged by the application")
      guard let installation else { return }
      Task {
        await sync.save([
          .pong(CompanionPong(nonce: nonce, macID: installation.id, receivedAt: receivedAt))
        ])
        await sync.delete([CompanionRecordName.ping(nonce)])
        await sync.note("test \(nonce.prefix(4)) accusé")
        sendSoon()
      }
    case .remoteSend(let peer, let message):
      let echo = self.echo
      Task { await echo.send(message, to: peer) }
    case .remoteDrop(let peer):
      let echo = self.echo
      Task { await echo.drop(peer) }
    case .removeDevice(let endpointID):
      Self.logger.notice("link: removing the phone \(endpointID.prefix(10), privacy: .public)")
      let echo = self.echo
      Task {
        await sync.delete([CompanionRecordName.device(endpointID)])
        await echo.drop(endpoint: endpointID)
        sendSoon()
      }
    case .welcome, .testReceived, .remoteReceived, .remoteClosed, .remoteOpened, .agentStatus,
      .devices, .answerReceived:
      Self.logger.notice("link: unexpected message from the application")
    }
  }

  // MARK: - Direct channel

  /// Whether a phone's endpoint is one of the user's: a `device` record of their private database,
  /// where nobody else writes (#398). A phone just paired may not be fetched yet: the zone is
  /// asked once more before it is refused.
  private func isPaired(_ endpointID: String) async -> Bool {
    if CompanionAdmission.admits(endpointID, among: records) { return true }
    await sync.fetchChanges()
    // The fetched records reach `records` through a task of the main actor.
    try? await Task.sleep(for: .milliseconds(500))
    return CompanionAdmission.admits(endpointID, among: records)
  }

  /// What the settings say of the agent: sent at each change.
  private var sentStatus: (signedIn: Bool, reachable: Bool)?
  private var sentDevices: [CompanionDevice]?

  private func reportStatus(signedIn: Bool) {
    let status = (signedIn: signedIn, reachable: irohAddress != nil)
    guard sentStatus.map({ $0 != status }) ?? true, let connection else { return }
    sentStatus = status
    connection.send(.agentStatus(signedIn: status.signedIn, reachable: status.reachable))
  }

  private func reportDevices() {
    let devices = records.compactMap { record -> CompanionDevice? in
      if case .device(let device) = record { return device }
      return nil
    }.sorted { $0.endpointID < $1.endpointID }
    guard devices != sentDevices, let connection else { return }
    sentDevices = devices
    connection.send(.devices(devices))
  }

  /// A phone's words, to the application; its departure too.
  private func relay(_ event: CompanionEchoServer.RemoteEvent) {
    switch event {
    case .opened(let peer, let endpointID):
      connection?.send(.remoteOpened(peer: peer, endpointID: endpointID))
    case .received(let peer, let message):
      connection?.send(.remoteReceived(peer: peer, message))
    case .closed(let peer):
      connection?.send(.remoteClosed(peer: peer))
    }
  }

  /// Sends what is pending now, without anyone waiting for it.
  private func sendSoon() {
    Task { await sync.sendChanges() }
  }

  /// The application went: the Mac is said offline, and the agent goes too.
  private func linkClosed() async {
    connection = nil
    Self.logger.notice("link closed: quitting")
    await quit()
  }

  /// Leaves from within a task, where `NSApp.terminate` cannot: its wait for the reply would hold
  /// the very queue the reply has to come from.
  private func quit() async {
    await depart()
    exit(0)
  }

  // MARK: - Records

  private func apply(_ update: CompanionSyncUpdate) {
    records = update.records
    reportStatus(signedIn: update.status.account == .available)
    reportDevices()
    if !update.fetched.isEmpty {
      Self.logger.notice(
        "apply: \(update.fetched.map(\.recordName).joined(separator: ", "), privacy: .public)")
    }
    let ownSessionsFetched = update.fetched.contains { record in
      if case .session(let session) = record { return session.macID == installation?.id }
      return false
    }
    if ownSessionsFetched {
      // Sessions this Mac wrote in an earlier run: the current snapshot replaces them.
      Task { await mergeSessions() }
    }
    answerTests()
    giveAnswers()
  }

  /// The answers the phone wrote from a notification (#401): handed to the application, which
  /// gives them if their request still waits, and deleted.
  private func giveAnswers() {
    guard let connection, let installation else { return }
    let answers = records.compactMap { record -> CompanionAnswer? in
      if case .answer(let answer) = record { return answer }
      return nil
    }
    let triage = CompanionAnswers.triage(
      answers, macID: installation.id, given: givenAnswers, now: Date())
    for answer in triage.toGive {
      Self.notifyLogger.notice(
        "answer: \(answer.choice.rawValue, privacy: .public) to \(answer.requestID, privacy: .public), handed to the application"
      )
      givenAnswers.insert(answer.id)
      connection.send(.answerReceived(answer))
    }
    guard !triage.toDelete.isEmpty else { return }
    Task {
      await sync.delete(triage.toDelete)
      sendSoon()
    }
  }

  private func answerTests() {
    guard let connection, installation != nil else { return }
    let pings = records.compactMap { record -> CompanionPing? in
      if case .ping(let ping) = record { return ping }
      return nil
    }
    let triage = CompanionInbox.triage(pings, handled: handled, now: Date())
    if !triage.toAnswer.isEmpty || !triage.toNotify.isEmpty || !triage.expired.isEmpty {
      Self.logger.notice(
        "triage: \(triage.toAnswer.count, privacy: .public) to answer, \(triage.toNotify.count, privacy: .public) to notify, \(triage.expired.count, privacy: .public) expired"
      )
    }
    for ping in triage.toNotify {
      handled.insert(ping.nonce)
      scheduleTestRequest(ping)
    }
    for ping in triage.toAnswer {
      let age = Date().timeIntervalSince(ping.sentAt)
      Self.logger.notice(
        "link: test \(ping.nonce, privacy: .public) handed to the application, sent \(age, format: .fixed(precision: 1), privacy: .public) s ago"
      )
      handled.insert(ping.nonce)
      connection.send(.testReceived(ping))
    }
    if !triage.expired.isEmpty {
      let names = triage.expired.map { CompanionRecordName.ping($0.nonce) }
      handled.formUnion(triage.expired.map(\.nonce))
      Task {
        await sync.delete(names)
        await sync.note("\(names.count) test(s) expiré(s) supprimé(s)")
        sendSoon()
      }
    }
  }

  private func mergeSessions() async {
    guard let installation, let snapshot else { return }
    let stored = records.compactMap { record -> CompanionSession? in
      if case .session(let session) = record { return session }
      return nil
    }
    let plan = CompanionSessionMerge.plan(
      snapshot: snapshot, stored: stored, macID: installation.id, now: Date())
    guard !plan.saves.isEmpty || !plan.deletions.isEmpty else { return }
    await sync.save(plan.saves.map(CompanionRecord.session))
    await sync.delete(plan.deletions)
  }

  // MARK: - Requests (#368)

  /// One `Request` per session that just started waiting for the user: the phone's subscription
  /// makes each a visible notification.
  private func writeRequests(for sessions: [CompanionSessionInfo]) async {
    guard let installation, !sessions.isEmpty else { return }
    let now = Date()
    let requests = sessions.map {
      CompanionRequests.request(for: $0, macID: installation.id, id: UUID().uuidString, now: now)
    }
    for request in requests {
      Self.notifyLogger.notice(
        "request: \(request.id, privacy: .public) for session \(request.sessionTitle, privacy: .private)"
      )
    }
    await sync.save(requests.map(CompanionRecord.request))
    await sync.note("\(requests.count) demande(s) écrite(s)")
  }

  /// A test of the notifications: a request written `requestDelay` after the phone sent it — time
  /// for the user to lock it — and the test deleted, without a pong or an alert on the Mac.
  private func scheduleTestRequest(_ ping: CompanionPing) {
    let delay = max(0, ping.sentAt.addingTimeInterval(ping.requestDelay ?? 0).timeIntervalSinceNow)
    Self.notifyLogger.notice(
      "test request: \(ping.nonce, privacy: .public), written in \(delay, format: .fixed(precision: 1), privacy: .public) s"
    )
    Task {
      await sync.delete([CompanionRecordName.ping(ping.nonce)])
      sendSoon()
      try? await Task.sleep(for: .seconds(delay))
      guard let installation, !isDeparting else { return }
      let request = CompanionRequest(
        id: UUID().uuidString, macID: installation.id, sessionTitle: "Vibe Manager",
        agent: Self.macName(), text: CompanionRequests.testText, createdAt: Date())
      Self.notifyLogger.notice("test request: \(request.id, privacy: .public) written")
      await sync.save([.request(request)])
      await sync.note("demande de test \(ping.nonce.prefix(4)) écrite")
      await sync.sendChanges()
    }
  }

  /// Deletes this Mac's requests past their hour: seen or not, they are worth nothing by then.
  private func purgeRequests() async {
    guard let installation else { return }
    let requests = records.compactMap { record -> CompanionRequest? in
      if case .request(let request) = record { return request }
      return nil
    }
    let names = CompanionRequests.expired(requests, macID: installation.id, now: Date())
    guard !names.isEmpty else { return }
    Self.notifyLogger.notice("purge: \(names.count, privacy: .public) request(s)")
    await sync.delete(names)
  }

  private func writeMac(online: Bool) async {
    guard let installation else { return }
    await sync.save([
      .mac(
        CompanionMac(
          installationID: installation.id, name: Self.macName(), version: installation.version,
          buildLabel: installation.buildLabel, online: online, lastSeen: Date(),
          irohEndpointID: online ? irohAddress?.endpointID : nil,
          irohRelayURL: online ? irohAddress?.relayURL : nil))
    ])
  }

  private static func macName() -> String {
    SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName
  }

  // MARK: - Schedule

  private func schedule() {
    // `lastSeen` at a pace the phone's push budget allows, which its tolerance is built on.
    timers.append(
      Timer.scheduledTimer(withTimeInterval: CompanionPresence.heartbeat, repeats: true) {
        [weak self] _ in
        Task { @MainActor in
          await self?.writeMac(online: true)
          await self?.purgeRequests()
          self?.sendSoon()
        }
      })
    timers.append(
      Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.poll() }
      })
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.writeMac(online: true)
        self?.sendSoon()
        await self?.sync.fetchChanges()
      }
    }
  }

  /// Every `pollInterval`, whether pushes arrive or not; one fetch at a time.
  private func poll() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    await sync.fetchChanges()
  }

  /// A push reached the agent: noted for the journal, and fetched at once.
  func pushReceived() {
    Task {
      await sync.notePush()
      await sync.fetchChanges()
    }
  }

  /// Writes the Mac offline and waits, a bounded time, for it to leave. Called once, on the way
  /// out, whatever the way.
  func depart() async {
    guard !isDeparting else { return }
    isDeparting = true
    timers.forEach { $0.invalidate() }
    connection?.close()
    // Whichever comes first: the write gone, or the limit. The other is cut short by the exit.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumed = ResumeOnce(continuation)
      Task { @MainActor in
        await self.writeMac(online: false)
        await self.sync.sendChanges()
        resumed.resume()
      }
      Task { await self.echo.stop() }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(Self.departureLimit))
        resumed.resume()
      }
    }
  }
}

/// Resumes a continuation the first time only, whoever asks first.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    let continuation = lock.withLock {
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}
