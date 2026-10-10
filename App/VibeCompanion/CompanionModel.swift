import CompanionCore
import CompanionKit
import Foundation
import Observation

/// What the debug screen shows, kept up to date by the synchronisation (#347).
@Observable
@MainActor
final class CompanionModel {
  private let sync: any CompanionSyncing
  private let deviceName: String

  private(set) var macs: [CompanionMac] = []
  private(set) var sessions: [CompanionSession] = []
  private(set) var status = CompanionSyncStatus()
  private(set) var journal: [CompanionJournalEntry] = []
  private(set) var testRun: CompanionTestRun?
  /// The Mac shown, when several — or several copies of the application — publish.
  var selectedMacID: String?
  /// When the screen last looked at the clock: what "connected" and "seen … ago" are read against.
  private(set) var now = Date()
  private var isStarted = false

  init(sync: any CompanionSyncing, deviceName: String) {
    self.sync = sync
    self.deviceName = deviceName
  }

  var selectedMac: CompanionMac? {
    macs.first { $0.installationID == selectedMacID } ?? macs.max { $0.lastSeen < $1.lastSeen }
  }

  var isConnected: Bool {
    selectedMac.map { CompanionPresence.isConnected($0, now: now) } ?? false
  }

  /// The selected Mac's sessions, read only.
  var visibleSessions: [CompanionSession] {
    guard let mac = selectedMac else { return [] }
    return sessions.filter { $0.macID == mac.installationID }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// Called once, at launch: the engine then listens to pushes.
  func start() async {
    guard !isStarted else { return }
    isStarted = true
    await sync.start { [weak self] update in
      Task { @MainActor in self?.apply(update) }
    }
    await sync.fetchChanges()
  }

  /// A fetch without a change costs one request and sends no push to anyone.
  func refresh() async {
    now = Date()
    await sync.fetchChanges()
    now = Date()
  }

  func notePush() async {
    await sync.notePush()
    await sync.fetchChanges()
  }

  func sendTest() async {
    let nonce = UUID().uuidString
    let ping = CompanionPing(nonce: nonce, deviceName: deviceName, sentAt: Date())
    testRun = CompanionTestRun(nonce: nonce, sentAt: ping.sentAt)
    await sync.save([.ping(ping)])
    await sync.note("ping \(nonce.prefix(4)) envoyé")
    await sync.sendChanges()
  }

  func apply(_ update: CompanionSyncUpdate) {
    now = Date()
    status = update.status
    journal = update.journal
    var pongs: [CompanionPong] = []
    var macs: [CompanionMac] = []
    var sessions: [CompanionSession] = []
    for record in update.records {
      switch record {
      case .mac(let mac): macs.append(mac)
      case .session(let session): sessions.append(session)
      case .pong(let pong): pongs.append(pong)
      case .ping: break
      }
    }
    self.macs = macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    self.sessions = sessions
    if var run = testRun {
      if update.sent.contains(CompanionRecordName.ping(run.nonce)) { run.markSent() }
      for pong in pongs where run.acknowledge(pong, at: now) {
        Task { await sync.note("accusé reçu, ping \(pong.nonce.prefix(4))") }
      }
      testRun = run
    }
    // A pong is read once: deleted as soon as it is here, whichever test it answered.
    if !pongs.isEmpty {
      let names = pongs.map { CompanionRecordName.pong($0.nonce) }
      Task {
        await sync.delete(names)
        await sync.sendChanges()
      }
    }
  }
}
