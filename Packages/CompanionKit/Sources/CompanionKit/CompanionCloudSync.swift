import CloudKit
import CompanionCore
import Foundation
import os

/// What the synchronisation keeps between launches: the records known here with their system
/// fields, and the engine's own state. Without either, every launch would fetch everything again
/// and every save would go out as a conflicting creation.
struct CompanionSyncStore: Codable {
  struct Entry: Codable {
    var record: CompanionRecord
    var systemFields: Data?
  }

  var entries: [String: Entry] = [:]
  var engineState: CKSyncEngine.State.Serialization?
  /// Where the direct fetch of the zone stands (`fetchZone`), archived.
  var zoneToken: Data?

  static func load(from url: URL) -> CompanionSyncStore {
    guard let data = try? Data(contentsOf: url),
      let store = try? JSONDecoder().decode(CompanionSyncStore.self, from: data)
    else { return CompanionSyncStore() }
    return store
  }

  func write(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(self).write(to: url, options: [.atomic])
  }
}

/// The companion's records in the private database, carried by `CKSyncEngine` (#347).
///
/// One per device and per database, created at launch and kept: two engines on the same database
/// tread on each other. On the Mac it runs in the companion agent alone, never in the application.
/// An actor, which the engine's delegate must be (`AnyObject, Sendable`): the engine calls it one
/// event at a time.
public actor CompanionCloudSync: CompanionSyncing, CKSyncEngineDelegate {
  private static let logger = Logger(
    subsystem: "eu.hadrien.VibeManager.companion", category: "sync")

  private let container: CKContainer
  private let storeURL: URL
  private var store: CompanionSyncStore
  /// Held strongly here: an engine let go stops listening.
  private var engine: CKSyncEngine?
  private var journal = CompanionJournal()
  private var status = CompanionSyncStatus()
  private var onUpdate: (@Sendable (CompanionSyncUpdate) -> Void)?

  public init(
    containerIdentifier: String = CompanionCloud.containerIdentifier, storeURL: URL
  ) {
    container = CKContainer(identifier: containerIdentifier)
    self.storeURL = storeURL
    store = CompanionSyncStore.load(from: storeURL)
  }

  // MARK: - CompanionSyncing

  public func start(onUpdate: @escaping @Sendable (CompanionSyncUpdate) -> Void) async {
    self.onUpdate = onUpdate
    guard engine == nil else { return }
    makeEngine()
    await refreshAccountStatus()
  }

  /// The engine's fetch, then the zone's own.
  ///
  /// The engine only fetches a zone it was told changed, by a push: without one — entitlement,
  /// registration, a push lost — it says "no zone IDs needing to be fetched" and asks nothing (seen
  /// on the Mac's agent in the trial of #347). The zone is then asked directly, with a change token
  /// of its own: a fetch without changes costs one request and sends no push to anyone.
  public func fetchChanges() async {
    guard let engine else { return }
    Self.logger.notice("fetch: engine")
    do {
      try await engine.fetchChanges()
    } catch {
      fail("récupération", error)
    }
    await fetchZone()
  }

  public func sendChanges() async {
    guard let engine else { return }
    let pending = engine.state.pendingRecordZoneChanges.count
    Self.logger.notice("send: begin, \(pending, privacy: .public) pending")
    do {
      try await engine.sendChanges()
      Self.logger.notice("send: end")
    } catch {
      fail("envoi", error)
    }
  }

  /// The zone's changes since the last direct fetch, asked of the database itself.
  private func fetchZone() async {
    let database = container.privateCloudDatabase
    var token = store.zoneToken.flatMap {
      try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
    }
    var more = true
    while more {
      do {
        let changes = try await database.recordZoneChanges(
          inZoneWith: CompanionCloud.zoneID, since: token)
        let records = changes.modificationResultsByID.values.compactMap {
          try? $0.get().record
        }
        Self.logger.notice(
          "fetch: zone, \(records.count, privacy: .public) modified, \(changes.deletions.count, privacy: .public) deleted"
        )
        token = changes.changeToken
        store.zoneToken = try? NSKeyedArchiver.archivedData(
          withRootObject: changes.changeToken, requiringSecureCoding: true)
        apply(fetched: records, deleted: changes.deletions.map(\.recordID))
        more = changes.moreComing
      } catch let error as CKError where error.code == .zoneNotFound {
        // Nobody wrote in the zone yet: nothing to fetch.
        Self.logger.notice("fetch: zone not found yet")
        return
      } catch let error as CKError where error.code == .changeTokenExpired {
        store.zoneToken = nil
        token = nil
      } catch {
        fail("récupération directe", error)
        return
      }
    }
    status.lastFetch = Date()
    publish()
  }

  public func save(_ records: [CompanionRecord]) async {
    guard !records.isEmpty else { return }
    Self.logger.notice(
      "save: \(records.map(\.recordName).joined(separator: ", "), privacy: .public)")
    for record in records {
      store.entries[record.recordName, default: .init(record: record)].record = record
    }
    persist()
    engine?.state.add(
      pendingRecordZoneChanges: records.map { .saveRecord(CompanionCloud.recordID($0.recordName)) })
    publish()
  }

  public func delete(_ recordNames: [String]) async {
    guard !recordNames.isEmpty else { return }
    Self.logger.notice("delete: \(recordNames.joined(separator: ", "), privacy: .public)")
    for name in recordNames { store.entries[name] = nil }
    persist()
    engine?.state.add(
      pendingRecordZoneChanges: recordNames.map { .deleteRecord(CompanionCloud.recordID($0)) })
    publish()
  }

  public func notePush() async {
    Self.logger.notice("push received")
    status.lastPush = Date()
    journal.record("push reçu")
    publish()
  }

  public func note(_ text: String) async {
    journal.record(text)
    publish()
  }

  public func refreshAccountStatus() async {
    do {
      let account = CompanionAccountState(try await container.accountStatus())
      if account != status.account { journal.record("compte iCloud : \(account.label)") }
      status.account = account
    } catch {
      status.account = .couldNotDetermine
      fail("compte iCloud", error)
    }
    publish()
  }

  // MARK: - Engine

  private func makeEngine() {
    var configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase, stateSerialization: store.engineState,
      delegate: self)
    configuration.automaticallySync = true
    let engine = CKSyncEngine(configuration)
    self.engine = engine
    if store.engineState == nil {
      // The zone first: the engine sends it before any record it holds.
      engine.state.add(pendingDatabaseChanges: [
        .saveZone(CKRecordZone(zoneID: CompanionCloud.zoneID))
      ])
      // What was written before the state was lost — a reset account — goes again.
      engine.state.add(
        pendingRecordZoneChanges: store.entries.keys.map {
          .saveRecord(CompanionCloud.recordID($0))
        })
      journal.record("moteur démarré, premier lancement")
    } else {
      journal.record("moteur démarré, état restauré")
    }
    publish()
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    Self.logger.notice("event: \(Self.name(of: event), privacy: .public)")
    switch event {
    case .stateUpdate(let update):
      store.engineState = update.stateSerialization
      persist()
    case .accountChange(let change):
      handleAccountChange(change, syncEngine)
    case .fetchedDatabaseChanges(let changes):
      handleDatabaseChanges(changes, syncEngine)
    case .fetchedRecordZoneChanges(let changes):
      handleFetched(changes)
    case .sentRecordZoneChanges(let sent):
      handleSent(sent, syncEngine)
    case .sentDatabaseChanges(let sent):
      for failure in sent.failedZoneSaves {
        fail("zone \(failure.zone.zoneID.zoneName)", failure.error)
      }
      if !sent.savedZones.isEmpty { journal.record("zone Companion enregistrée") }
      publish()
    case .didFetchChanges:
      status.lastFetch = Date()
      publish()
    case .didSendChanges:
      status.lastSend = Date()
      publish()
    case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
      .willSendChanges:
      break
    @unknown default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    // `options.scope.contains`: the `options.zoneIDs` of Apple's documentation does not exist.
    let pending = syncEngine.state.pendingRecordZoneChanges.filter {
      context.options.scope.contains($0)
    }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
      await self.recordToSend(id, syncEngine)
    }
  }

  private func recordToSend(_ id: CKRecord.ID, _ engine: CKSyncEngine) -> CKRecord? {
    guard let entry = store.entries[id.recordName] else {
      // Deleted here since it was queued: nothing left to send.
      engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
      return nil
    }
    return CompanionRecordCodec.makeRecord(entry.record, systemFields: entry.systemFields)
  }

  private func handleAccountChange(
    _ change: CKSyncEngine.Event.AccountChange, _ engine: CKSyncEngine
  ) {
    switch change.changeType {
    case .signIn:
      journal.record("compte iCloud connecté")
      engine.state.add(pendingDatabaseChanges: [
        .saveZone(CKRecordZone(zoneID: CompanionCloud.zoneID))
      ])
      engine.state.add(
        pendingRecordZoneChanges: store.entries.keys.map {
          .saveRecord(CompanionCloud.recordID($0))
        })
    case .signOut, .switchAccounts:
      // Another account's records are not this one's: forgotten, and the engine made anew.
      journal.record("compte iCloud changé : données locales effacées")
      store = CompanionSyncStore()
      persist()
      Task { self.remakeEngine() }
    @unknown default:
      break
    }
    publish()
  }

  private func remakeEngine() {
    engine = nil
    makeEngine()
  }

  private func handleDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges, _ engine: CKSyncEngine
  ) {
    for deletion in changes.deletions where deletion.zoneID == CompanionCloud.zoneID {
      switch deletion.reason {
      case .encryptedDataReset:
        // The iCloud keychain was reset: the encrypted fields are lost, everything goes again.
        journal.record("zone réinitialisée (trousseau) : tout est renvoyé")
        for name in store.entries.keys { store.entries[name]?.systemFields = nil }
        engine.state.add(pendingDatabaseChanges: [
          .saveZone(CKRecordZone(zoneID: CompanionCloud.zoneID))
        ])
        engine.state.add(
          pendingRecordZoneChanges: store.entries.keys.map {
            .saveRecord(CompanionCloud.recordID($0))
          })
      case .deleted, .purged:
        journal.record("zone Companion supprimée")
        store.entries = [:]
      @unknown default:
        break
      }
    }
    persist()
    publish()
  }

  private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
    apply(
      fetched: changes.modifications.map(\.record), deleted: changes.deletions.map(\.recordID))
  }

  /// Records from iCloud, by the engine or by the direct fetch. A record this device still has to
  /// send keeps its own content — the server's is older — and only takes the server's change tag.
  private func apply(fetched ckRecords: [CKRecord], deleted: [CKRecord.ID]) {
    let pending = engine?.state.pendingRecordZoneChanges ?? []
    let pendingSaves = Set(
      pending.compactMap { change -> String? in
        if case .saveRecord(let id) = change { return id.recordName }
        return nil
      })
    // Deleted here, not yet in iCloud: the server's copy is not brought back.
    let pendingDeletes = Set(
      pending.compactMap { change -> String? in
        if case .deleteRecord(let id) = change { return id.recordName }
        return nil
      })
    var fetched: [CompanionRecord] = []
    for ckRecord in ckRecords {
      guard let record = CompanionRecordCodec.decode(ckRecord) else { continue }
      let name = record.recordName
      if pendingDeletes.contains(name) { continue }
      if pendingSaves.contains(name), store.entries[name] != nil {
        store.entries[name]?.systemFields = ckRecord.archivedSystemFields
        continue
      }
      if store.entries[name]?.record != record { fetched.append(record) }
      store.entries[name] = .init(record: record, systemFields: ckRecord.archivedSystemFields)
    }
    var removed = 0
    for id in deleted where store.entries.removeValue(forKey: id.recordName) != nil {
      removed += 1
    }
    persist()
    if !fetched.isEmpty || removed > 0 {
      var line = "récupéré"
      if !fetched.isEmpty {
        line += " : " + CompanionJournal.summary(fetched.map(CompanionRecordCodec.recordType(of:)))
      }
      if removed > 0 { line += " ; \(removed) suppression(s)" }
      journal.record(line)
      Self.logger.notice(
        "apply: \(fetched.map(\.recordName).joined(separator: ", "), privacy: .public); \(removed, privacy: .public) removed"
      )
    }
    publish(fetched: fetched)
  }

  private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, _ engine: CKSyncEngine)
  {
    var retry: [CKSyncEngine.PendingRecordZoneChange] = []
    var zones: [CKSyncEngine.PendingDatabaseChange] = []
    for ckRecord in sent.savedRecords {
      store.entries[ckRecord.recordID.recordName]?.systemFields = ckRecord.archivedSystemFields
    }
    for failure in sent.failedRecordSaves {
      let id = failure.record.recordID
      switch failure.error.code {
      case .serverRecordChanged:
        // Every record a device sends is its own to write: this device's version wins, on top of
        // the server's change tag.
        if let server = failure.error.serverRecord {
          store.entries[id.recordName]?.systemFields = server.archivedSystemFields
          retry.append(.saveRecord(id))
        }
      case .zoneNotFound, .userDeletedZone:
        zones.append(.saveZone(CKRecordZone(zoneID: id.zoneID)))
        store.entries[id.recordName]?.systemFields = nil
        retry.append(.saveRecord(id))
      case .unknownItem:
        store.entries[id.recordName]?.systemFields = nil
        retry.append(.saveRecord(id))
      default:
        // Network, rate limits, account: retried by the engine. The rest is said.
        fail("envoi de \(id.recordName)", failure.error)
      }
    }
    engine.state.add(pendingDatabaseChanges: zones)
    engine.state.add(pendingRecordZoneChanges: retry)
    persist()
    let names = sent.savedRecords.map(\.recordID.recordName)
    if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
      var line = "envoyé"
      if !sent.savedRecords.isEmpty {
        line += " : " + CompanionJournal.summary(sent.savedRecords.map(\.recordType))
      }
      if !sent.deletedRecordIDs.isEmpty {
        line += " ; \(sent.deletedRecordIDs.count) suppression(s)"
      }
      journal.record(line)
    }
    publish(sent: names)
  }

  // MARK: - Bookkeeping

  static func name(of event: CKSyncEngine.Event) -> String {
    switch event {
    case .stateUpdate: "stateUpdate"
    case .accountChange(let change): "accountChange \(change.changeType)"
    case .fetchedDatabaseChanges(let changes):
      "fetchedDatabaseChanges \(changes.modifications.count) modified, \(changes.deletions.count) deleted"
    case .fetchedRecordZoneChanges(let changes):
      "fetchedRecordZoneChanges \(changes.modifications.count) modified, \(changes.deletions.count) deleted"
    case .sentDatabaseChanges(let sent):
      "sentDatabaseChanges \(sent.savedZones.count) saved, \(sent.failedZoneSaves.count) failed"
    case .sentRecordZoneChanges(let sent):
      "sentRecordZoneChanges \(sent.savedRecords.count) saved, \(sent.deletedRecordIDs.count) deleted, \(sent.failedRecordSaves.count) failed"
    case .willFetchChanges: "willFetchChanges"
    case .willFetchRecordZoneChanges: "willFetchRecordZoneChanges"
    case .didFetchRecordZoneChanges(let done):
      "didFetchRecordZoneChanges \(done.error.map { "\($0.code.rawValue)" } ?? "ok")"
    case .didFetchChanges: "didFetchChanges"
    case .willSendChanges: "willSendChanges"
    case .didSendChanges: "didSendChanges"
    @unknown default: "unknown"
    }
  }

  private func fail(_ step: String, _ error: any Error) {
    let text = CompanionErrorText.describe(error)
    status.lastError = "\(step) : \(text)"
    journal.record("erreur, \(step) : \(text)")
    Self.logger.error("\(step, privacy: .public): \(text, privacy: .public)")
    publish()
  }

  private func persist() {
    do {
      try store.write(to: storeURL)
    } catch {
      Self.logger.error("store not written: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func publish(fetched: [CompanionRecord] = [], sent: [String] = []) {
    status.pendingChanges = engine?.state.pendingRecordZoneChanges.count ?? 0
    onUpdate?(
      CompanionSyncUpdate(
        records: store.entries.values.map(\.record), status: status, journal: journal.entries,
        fetched: fetched, sent: sent))
  }
}
