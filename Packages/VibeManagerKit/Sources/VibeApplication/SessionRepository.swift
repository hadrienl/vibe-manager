import VibeDomain

public protocol SessionRepository: Sendable {
  func sessions() async throws -> [WorkSession]
  func session(id: SessionID) async throws -> WorkSession?
  func save(_ session: WorkSession) async throws
  /// Applies `transform` to the stored session and persists the result as a single
  /// atomic step, so concurrent callers cannot lose each other's changes.
  /// Returns `nil` when no session matches `id`.
  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession?
}

extension SessionRepository {
  /// Fallback for repositories that cannot serialize the read-modify-write themselves.
  /// Concurrent callers can overwrite each other here; conformers that own their
  /// storage (actors, databases) should provide an atomic implementation instead.
  ///
  /// Such an implementation has to be declared `async`, as `FileSessionRepository` and
  /// `InMemorySessionRepository` are. A synchronous method on an actor still satisfies the
  /// requirement, so it is used through `any SessionRepository` — but a caller holding the
  /// concrete type resolves to this default instead, and loses the atomicity without a word.
  public func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) async throws -> WorkSession? {
    guard var session = try await session(id: id) else { return nil }
    try transform(&session)
    try await save(session)
    return session
  }
}

public enum SessionStoreRecoveryStatus: Equatable, Sendable {
  case notNeeded
  case backupAvailable
  case unavailable
  /// The store was written by a newer version of the application. Restoring an older backup over
  /// it would silently downgrade it and lose that version's data, so it must be left untouched.
  case unsupportedVersion
  /// The store exists but its bytes cannot be read, so the damaged document cannot be quarantined
  /// either. Restoring would destroy the only diagnostic evidence left.
  case storeUnreadable
}

public protocol SessionStoreRecovery: Sendable {
  func recoveryStatus() async -> SessionStoreRecoveryStatus
  func restoreBackup() async throws
}
