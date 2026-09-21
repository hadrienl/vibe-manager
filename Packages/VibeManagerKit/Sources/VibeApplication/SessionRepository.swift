import VibeDomain

public protocol SessionRepository: Sendable {
  func sessions() async throws -> [WorkSession]
  func session(id: SessionID) async throws -> WorkSession?
  func save(_ session: WorkSession) async throws
}

public enum SessionStoreRecoveryStatus: Equatable, Sendable {
  case notNeeded
  case backupAvailable
  case unavailable
}

public protocol SessionStoreRecovery: Sendable {
  func recoveryStatus() async -> SessionStoreRecoveryStatus
  func restoreBackup() async throws
}
