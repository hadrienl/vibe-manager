import Foundation
import VibeApplication
import VibeDomain

public enum SessionStoreError: Error, Equatable, LocalizedError, Sendable {
  case cannotAccessStore
  case corruptedStore(backupAvailable: Bool)
  case invalidSession
  case unsupportedSchemaVersion(Int)
  case recoveryUnavailable

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
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.hadrienl.VibeManager", isDirectory: true)
      .appendingPathComponent("sessions.json", isDirectory: false)
  }

  public func sessions() throws -> [WorkSession] {
    try loadSessions().sorted(by: Self.sessionOrdering)
  }

  public func session(id: SessionID) throws -> WorkSession? {
    try loadSessions().first { $0.id == id }
  }

  public func save(_ session: WorkSession) throws {
    do {
      try session.validate()
      var current = try loadSessions()
      if let index = current.firstIndex(where: { $0.id == session.id }) {
        current[index] = session
      } else {
        current.append(session)
      }
      let data = try codec.encode(sessions: current.sorted(by: Self.sessionOrdering))
      try commit(data, preservingCurrentAsBackup: true)
    } catch let error as SessionStoreError {
      throw error
    } catch let error as SessionStoreCodecError {
      throw mapCodecError(error)
    } catch is WorkSessionValidationError {
      throw SessionStoreError.invalidSession
    } catch {
      throw SessionStoreError.cannotAccessStore
    }
  }

  public func recoveryStatus() -> SessionStoreRecoveryStatus {
    let manager = FileManager.default
    guard manager.fileExists(atPath: storeURL.path) else { return .notNeeded }
    do {
      let data = try Data(contentsOf: storeURL)
      _ = try codec.decode(data)
      return .notNeeded
    } catch {
      return backupIsValid() ? .backupAvailable : .unavailable
    }
  }

  public func restoreBackup() throws {
    guard let backupData = try? Data(contentsOf: backupURL),
      let decoded = try? codec.decode(backupData)
    else {
      throw SessionStoreError.recoveryUnavailable
    }

    do {
      if let damagedData = try? Data(contentsOf: storeURL) {
        let quarantineURL = storeURL.deletingPathExtension()
          .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        try atomicWrite(damagedData, to: quarantineURL, invokingInterruption: false)
      }
      let recoveredData = try codec.encode(sessions: decoded.sessions)
      try commit(recoveredData, preservingCurrentAsBackup: false)
    } catch let error as SessionStoreError {
      throw error
    } catch {
      throw SessionStoreError.cannotAccessStore
    }
  }

  private func loadSessions() throws -> [WorkSession] {
    guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }

    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch {
      throw SessionStoreError.cannotAccessStore
    }

    do {
      let decoded = try codec.decode(data)
      if decoded.requiresRewrite {
        let migratedData = try codec.encode(sessions: decoded.sessions)
        try commit(migratedData, preservingCurrentAsBackup: true)
      }
      return decoded.sessions
    } catch let error as SessionStoreCodecError {
      switch error {
      case .unsupportedSchemaVersion(let version):
        throw SessionStoreError.unsupportedSchemaVersion(version)
      case .invalidStore:
        throw SessionStoreError.corruptedStore(backupAvailable: backupIsValid())
      }
    } catch let error as SessionStoreError {
      throw error
    } catch {
      throw SessionStoreError.cannotAccessStore
    }
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
    try handle.write(contentsOf: data)
    try handle.synchronize()
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
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func backupIsValid() -> Bool {
    guard let data = try? Data(contentsOf: backupURL) else { return false }
    return (try? codec.decode(data)) != nil
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
