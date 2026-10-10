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
  /// The application is the only peer: the same team, its identifier.
  private static let applicationIdentifier = "eu.hadrien.VibeManager"
  /// How often the agent asks iCloud itself, on top of the pushes: without them — entitlement
  /// missing, push lost — nothing would ever be fetched.
  private static let fetchInterval: TimeInterval = 5 * 60
  /// How often polling is considered; see `poll`.
  private static let pollInterval: TimeInterval = 30
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
  private let arguments: Arguments
  private var connection: CompanionLinkConnection?
  private var installation: Installation?
  private var records: [CompanionRecord] = []
  private var snapshot: [CompanionSessionInfo]?
  /// The tests handed to the application, so that a record fetched twice raises one alert.
  private var handled: Set<String> = []
  private var timers: [Timer] = []
  private var isDeparting = false
  /// Keeps App Nap away: a process without a window is its first candidate, and a napping agent's
  /// heartbeat could come later than the phone's tolerance. The Mac may still sleep.
  private var activity: (any NSObjectProtocol)?
  private var lastPush: Date?
  private var lastFetch: Date?

  init(arguments: Arguments) {
    self.arguments = arguments
    sync = CompanionCloudSync(
      storeURL: arguments.stateDirectory.appendingPathComponent("sync.json", isDirectory: false))
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
    await sync.fetchChanges()
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
      Task {
        await sync.note("application connectée (\(buildLabel.isEmpty ? version : buildLabel))")
        await writeMac(online: true)
        await mergeSessions()
        sendSoon()
      }
      answerTests()
    case .snapshot(let sessions):
      Self.logger.notice("link: snapshot of \(sessions.count, privacy: .public) session(s)")
      snapshot = sessions
      Task {
        await mergeSessions()
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
    case .welcome, .testReceived:
      Self.logger.notice("link: unexpected message from the application")
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
  }

  private func answerTests() {
    guard let connection, installation != nil else { return }
    let pings = records.compactMap { record -> CompanionPing? in
      if case .ping(let ping) = record { return ping }
      return nil
    }
    let triage = CompanionInbox.triage(pings, handled: handled, now: Date())
    if !triage.toAnswer.isEmpty || !triage.expired.isEmpty {
      Self.logger.notice(
        "triage: \(triage.toAnswer.count, privacy: .public) to answer, \(triage.expired.count, privacy: .public) expired"
      )
    }
    for ping in triage.toAnswer {
      Self.logger.notice("link: test \(ping.nonce, privacy: .public) handed to the application")
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

  private func writeMac(online: Bool) async {
    guard let installation else { return }
    await sync.save([
      .mac(
        CompanionMac(
          installationID: installation.id, name: Self.macName(), version: installation.version,
          buildLabel: installation.buildLabel, online: online, lastSeen: Date()))
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

  /// Every 30 s while no push came in the last half hour, every 5 min otherwise: without pushes, a
  /// test would wait for the next fetch — which is all this is, then.
  private func poll() async {
    let now = Date()
    let pushesArrive = lastPush.map { now.timeIntervalSince($0) < 30 * 60 } ?? false
    if pushesArrive, let lastFetch, now.timeIntervalSince(lastFetch) < Self.fetchInterval {
      return
    }
    lastFetch = now
    await sync.fetchChanges()
  }

  /// A push reached the agent: noted, so that polling slows down, and fetched.
  func pushReceived() {
    lastPush = Date()
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
