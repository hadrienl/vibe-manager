import Foundation
import VibeApplication
import VibeDomain

public enum SessionStoreError: Error, Equatable, LocalizedError, Sendable {
  case cannotAccessStore
  case corruptedStore(backupAvailable: Bool)
  case invalidSession
  case unsupportedSchemaVersion(Int)
  case recoveryUnavailable
  case recoveryNotNeeded
  case recoveryRefusedForNewerStore

  public var errorDescription: String? {
    switch self {
    case .cannotAccessStore:
      return "The session store could not be accessed."
    case .corruptedStore(let backupAvailable):
      return backupAvailable
        ? "The session store is damaged, but a backup can be restored."
        : "The session store is damaged and no valid backup is available."
    case .invalidSession:
      return "The work session contains invalid data."
    case .unsupportedSchemaVersion:
      return "The session store was created by a newer version of Vibe Manager."
    case .recoveryUnavailable:
      return "No valid session backup is available."
    case .recoveryNotNeeded:
      return "The session store is healthy, so there is nothing to restore."
    case .recoveryRefusedForNewerStore:
      return """
        The session store was created by a newer version of Vibe Manager and must not be replaced \
        by an older backup. Update Vibe Manager to open it.
        """
    }
  }
}

public actor FileSessionRepository: SessionRepository, SessionStoreRecovery {
  private let storeURL: URL
  private let backupURL: URL
  private let codec = SessionStoreCodec()
  private let beforeReplace: (@Sendable () throws -> Void)?

  public init(storeURL: URL = FileSessionRepository.defaultStoreURL()) {
    self.storeURL = storeURL
    backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
    beforeReplace = nil
  }

  init(storeURL: URL, beforeReplace: @escaping @Sendable () throws -> Void) {
    self.storeURL = storeURL
    backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
    self.beforeReplace = beforeReplace
  }

  public static func defaultStoreURL() -> URL {
    let applicationSupport =
      FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return
      applicationSupport
      .appendingPathComponent("com.hadrienl.VibeManager", isDirectory: true)
      .appendingPathComponent("sessions.json", isDirectory: false)
  }

  public func sessions() throws -> [WorkSession] {
    try loadSessions(persistingMigration: true).sorted(by: Self.sessionOrdering)
  }

  public func session(id: SessionID) throws -> WorkSession? {
    try loadSessions(persistingMigration: true).first { $0.id == id }
  }

  public func save(_ session: WorkSession) throws {
    do {
      try session.validate()
      var current = try loadSessions(persistingMigration: false)
      if let index = current.firstIndex(where: { $0.id == session.id }) {
        current[index] = session
      } else {
        current.append(session)
      }
      try persist(current)
    } catch {
      throw mapStoreError(error)
    }
  }

  public func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession? {
    var current: [WorkSession]
    do {
      current = try loadSessions(persistingMigration: false)
    } catch {
      throw mapStoreError(error)
    }

    guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
    var session = current[index]
    try transform(&session)

    do {
      try session.validate()
      current[index] = session
      try persist(current)
    } catch {
      throw mapStoreError(error)
    }
    return session
  }

  public func recoveryStatus() -> SessionStoreRecoveryStatus {
    guard FileManager.default.fileExists(atPath: storeURL.path) else { return .notNeeded }
    guard let data = try? Data(contentsOf: storeURL) else { return .storeUnreadable }
    do {
      _ = try codec.decode(data)
      return .notNeeded
    } catch SessionStoreCodecError.unsupportedSchemaVersion {
      // A document from a newer version decodes as a failure here, but it is not damage.
      return .unsupportedVersion
    } catch {
      return backupIsValid() ? .backupAvailable : .unavailable
    }
  }

  public func restoreBackup() throws {
    // Restoring rewinds the store to its previous state and quarantines the current
    // document, so it must never run against a store that is still readable.
    switch recoveryStatus() {
    case .notNeeded:
      throw SessionStoreError.recoveryNotNeeded
    case .unavailable:
      throw SessionStoreError.recoveryUnavailable
    case .unsupportedVersion:
      throw SessionStoreError.recoveryRefusedForNewerStore
    case .storeUnreadable:
      throw SessionStoreError.cannotAccessStore
    case .backupAvailable:
      break
    }

    guard let backupData = try? Data(contentsOf: backupURL),
      let decoded = try? codec.decode(backupData)
    else {
      throw SessionStoreError.recoveryUnavailable
    }

    do {
      // The damaged bytes are the only diagnostic evidence left, so failing to preserve them
      // aborts the restoration rather than silently discarding them.
      let damagedData = try Data(contentsOf: storeURL)
      let quarantineURL = storeURL.deletingPathExtension()
        .appendingPathExtension("corrupt-\(UUID().uuidString).json")
      try atomicWrite(damagedData, to: quarantineURL, invokingInterruption: false)
      let recoveredData = try codec.encode(sessions: decoded.sessions)
      try commit(recoveredData, preservingCurrentAsBackup: false)
    } catch let error as SessionStoreError {
      throw error
    } catch {
      throw SessionStoreError.cannotAccessStore
    }
  }

  /// - Parameter persistingMigration: when `true`, a migrated legacy document is written back on a
  ///   best-effort basis. A caller that is about to commit itself passes `false`, so that the
  ///   single backup it produces holds the original pre-migration bytes rather than an already
  ///   migrated copy of them.
  private func loadSessions(persistingMigration: Bool) throws -> [WorkSession] {
    guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }

    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch {
      throw SessionStoreError.cannotAccessStore
    }

    do {
      let decoded = try codec.decode(data)
      if decoded.requiresRewrite, persistingMigration {
        // Reading must succeed even when the migrated document cannot be written
        // back, for instance on a full disk or a read-only container.
        if let migratedData = try? codec.encode(sessions: decoded.sessions) {
          try? commit(migratedData, preservingCurrentAsBackup: true)
        }
      }
      return decoded.sessions
    } catch let error as SessionStoreCodecError {
      throw mapCodecError(error)
    } catch let error as SessionStoreError {
      throw error
    } catch {
      throw SessionStoreError.cannotAccessStore
    }
  }

  private func persist(_ sessions: [WorkSession]) throws {
    let data = try codec.encode(sessions: sessions.sorted(by: Self.sessionOrdering))
    try commit(data, preservingCurrentAsBackup: true)
  }

  private func commit(_ data: Data, preservingCurrentAsBackup: Bool) throws {
    try ensureStoreDirectory()
    if preservingCurrentAsBackup,
      FileManager.default.fileExists(atPath: storeURL.path)
    {
      let currentData = try Data(contentsOf: storeURL)
      try atomicWrite(currentData, to: backupURL, invokingInterruption: false)
    }
    try atomicWrite(data, to: storeURL, invokingInterruption: true)
  }

  private func atomicWrite(_ data: Data, to destination: URL, invokingInterruption: Bool) throws {
    try ensureStoreDirectory()
    let manager = FileManager.default
    let temporaryURL = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }

    guard
      manager.createFile(
        atPath: temporaryURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw SessionStoreError.cannotAccessStore
    }
    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
    } catch {
      try? handle.close()
      throw error
    }
    try handle.close()

    if invokingInterruption {
      try beforeReplace?()
    }
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: destination)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  /// Creates the store directory with owner-only permissions.
  ///
  /// A directory that already exists keeps its own permissions: the store URL is caller-provided,
  /// so it may point inside a directory the application does not own, and tightening that one to
  /// `0700` on every write would silently restrict unrelated content. The files themselves are
  /// always written as `0600`.
  private func ensureStoreDirectory() throws {
    let directory = storeURL.deletingLastPathComponent()
    let manager = FileManager.default
    if !manager.fileExists(atPath: directory.path) {
      try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
  }

  private func backupIsValid() -> Bool {
    guard let data = try? Data(contentsOf: backupURL) else { return false }
    return (try? codec.decode(data)) != nil
  }

  private func mapStoreError(_ error: Error) -> Error {
    switch error {
    case let error as SessionStoreError:
      return error
    case let error as SessionStoreCodecError:
      return mapCodecError(error)
    case is WorkSessionValidationError:
      return SessionStoreError.invalidSession
    default:
      return SessionStoreError.cannotAccessStore
    }
  }

  private func mapCodecError(_ error: SessionStoreCodecError) -> SessionStoreError {
    switch error {
    case .unsupportedSchemaVersion(let version):
      return .unsupportedSchemaVersion(version)
    case .invalidStore:
      return .corruptedStore(backupAvailable: backupIsValid())
    }
  }

  private static func sessionOrdering(_ lhs: WorkSession, _ rhs: WorkSession) -> Bool {
    if lhs.updatedAt == rhs.updatedAt {
      return lhs.id.description < rhs.id.description
    }
    return lhs.updatedAt > rhs.updatedAt
  }
}
