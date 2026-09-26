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
  /// Gives the sessions named their new rank in a single write (#44). Nothing else is touched —
  /// not even the last activity. A session no longer stored is skipped.
  func reorder(_ ranks: [SessionID: Int]) async throws
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

  /// Fallback for repositories that cannot write several sessions at once: one `mutate` per
  /// session, so a failure halfway leaves part of the order written. The file store and the
  /// in-memory one write it in one step.
  public func reorder(_ ranks: [SessionID: Int]) async throws {
    for (id, rank) in ranks {
      _ = try await mutate(id: id) { $0.rank = rank }
    }
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
