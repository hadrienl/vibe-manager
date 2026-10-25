import CloudKit
import CompanionCore
import Foundation

/// The iCloud account, as CloudKit says it.
public enum CompanionAccountState: String, Hashable, Sendable {
  case unknown
  case available
  case noAccount
  case restricted
  case couldNotDetermine
  case temporarilyUnavailable

  init(_ status: CKAccountStatus) {
    switch status {
    case .available: self = .available
    case .noAccount: self = .noAccount
    case .restricted: self = .restricted
    case .couldNotDetermine: self = .couldNotDetermine
    case .temporarilyUnavailable: self = .temporarilyUnavailable
    @unknown default: self = .couldNotDetermine
    }
  }

  /// Said on the debug screens, in French (#347: a debug application).
  public var label: String {
    switch self {
    case .unknown: "inconnu"
    case .available: "disponible"
    case .noAccount: "aucun compte"
    case .restricted: "restreint"
    case .couldNotDetermine: "indéterminé"
    case .temporarilyUnavailable: "temporairement indisponible"
    }
  }
}

/// Every step of the synchronisation that the debug screen shows (#347).
public struct CompanionSyncStatus: Equatable, Sendable {
  public var account: CompanionAccountState = .unknown
  public var lastFetch: Date?
  /// The last push CloudKit sent this device, when the platform tells.
  public var lastPush: Date?
  public var lastSend: Date?
  /// Records waiting to be sent.
  public var pendingChanges = 0
  public var lastError: String?

  public init() {}
}

/// What the synchronisation holds, handed over after each change.
public struct CompanionSyncUpdate: Sendable {
  /// Every record of the zone known on this device.
  public var records: [CompanionRecord]
  public var status: CompanionSyncStatus
  /// Newest first.
  public var journal: [CompanionJournalEntry]
  /// The records that just arrived from iCloud, if any: what a device reacts to.
  public var fetched: [CompanionRecord]
  /// The names of the records that just reached iCloud.
  public var sent: [String]

  public init(
    records: [CompanionRecord], status: CompanionSyncStatus, journal: [CompanionJournalEntry],
    fetched: [CompanionRecord] = [], sent: [String] = []
  ) {
    self.records = records
    self.status = status
    self.journal = journal
    self.fetched = fetched
    self.sent = sent
  }
}

/// The synchronisation, as the phone and the Mac's agent drive it: CloudKit behind it in the
/// applications (`CompanionCloudSync`), a fake in the tests and the previews.
public protocol CompanionSyncing: AnyObject, Sendable {
  /// Starts the engine, once: it then listens to pushes and to its own scheduler. `onUpdate` is
  /// called after every change, from the synchronisation's own executor.
  func start(onUpdate: @escaping @Sendable (CompanionSyncUpdate) -> Void) async
  /// Asks iCloud what changed: without a push entitlement, or with a push lost, nothing else does.
  func fetchChanges() async
  /// Sends what is pending now rather than when the engine's scheduler would.
  func sendChanges() async
  /// Writes records here, and queues them for iCloud.
  func save(_ records: [CompanionRecord]) async
  /// Deletes records here, and queues their deletion in iCloud.
  func delete(_ recordNames: [String]) async
  /// A push reached the application: noted for the debug screen.
  func notePush() async
  /// A line of the device's own in the journal.
  func note(_ text: String) async
  func refreshAccountStatus() async
}
