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
  /// The phones admitted to the direct channel.
  private(set) var devices: [CompanionDevice] = []
  private(set) var status = CompanionSyncStatus()
  private(set) var journal: [CompanionJournalEntry] = []
  private(set) var testRun: CompanionTestRun?
  /// The newest request in the zone (#368), whichever Mac wrote it, notified or not.
  private(set) var latestRequest: CompanionRequest?
  /// When the last test of the notifications was sent, by the phone's clock.
  private(set) var notificationTestSentAt: Date?
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

  /// This phone, admitted to the Mac's direct channel (#398): its endpoint written in the user's
  /// private database, once — again only if the record went missing.
  func register(endpointID: String) async {
    guard !devices.contains(where: { $0.endpointID == endpointID }) else { return }
    await sync.save([
      .device(CompanionDevice(endpointID: endpointID, name: deviceName, addedAt: Date()))
    ])
    await sync.note("iPhone appairé : \(endpointID.prefix(10))")
    await sync.sendChanges()
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

  /// Asks the Mac for a request in `delay` seconds, without an alert on its side: time to lock the
  /// phone and see the notification come (#368).
  func sendNotificationTest(delay: TimeInterval = 10) async {
    let nonce = UUID().uuidString
    let ping = CompanionPing(
      nonce: nonce, deviceName: deviceName, sentAt: Date(), requestDelay: delay)
    notificationTestSentAt = ping.sentAt
    await sync.save([.ping(ping)])
    await sync.note("test de notification \(nonce.prefix(4)) envoyé")
    await sync.sendChanges()
  }

  func apply(_ update: CompanionSyncUpdate) {
    now = Date()
    status = update.status
    journal = update.journal
    var pongs: [CompanionPong] = []
    var macs: [CompanionMac] = []
    var sessions: [CompanionSession] = []
    var requests: [CompanionRequest] = []
    var devices: [CompanionDevice] = []
    for record in update.records {
      switch record {
      case .mac(let mac): macs.append(mac)
      case .session(let session): sessions.append(session)
      case .pong(let pong): pongs.append(pong)
      case .request(let request): requests.append(request)
      case .device(let device): devices.append(device)
      case .ping, .answer: break
      }
    }
    self.devices = devices
    latestRequest = requests.max { $0.createdAt < $1.createdAt }
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
