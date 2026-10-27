import Foundation
import VibeDomain

/// Forms the batches as sessions are archived, and keeps them (#408).
public actor ArchiveReportBook {
  private let store: any ArchiveReportStore

  public init(store: any ArchiveReportStore) {
    self.store = store
  }

  public func batches() async -> [ArchiveBatch] {
    await store.batches()
  }

  /// A run of a rule that archived something, or on trial would have. Nothing is formed when
  /// nothing left, or would have left, the list.
  @discardableResult
  public func recordRun(
    kind: ArchiveBatch.Kind, date: Date, sessions: [ArchivedSessionSnapshot],
    skipped: [SkippedSession]
  ) async throws -> ArchiveBatch? {
    guard !sessions.isEmpty else { return nil }
    let batch = ArchiveBatch(kind: kind, date: date, sessions: sessions, skipped: skipped)
    try await store.save(batch)
    return batch
  }

  /// An archive by hand, added to the day's batch: pressing ⌃⌘A ten times makes one batch, not
  /// ten. A session archived again the same day stands as it was the last time.
  @discardableResult
  public func recordByHand(_ snapshot: ArchivedSessionSnapshot, calendar: Calendar) async throws
    -> ArchiveBatch
  {
    let day = calendar.startOfDay(for: snapshot.archivedAt)
    var batch =
      await store.batches().last {
        $0.kind == .manual && calendar.startOfDay(for: $0.date) == day
      } ?? ArchiveBatch(kind: .manual, date: snapshot.archivedAt)
    batch.sessions.removeAll { $0.sessionID == snapshot.sessionID }
    batch.sessions.append(snapshot)
    try await store.save(batch)
    return batch
  }

  /// Keeps the agent's paragraph, or that it failed, with the batch it was written over.
  public func setSynthesis(_ synthesis: ArchiveSynthesis, of id: UUID) async throws {
    guard var batch = await store.batches().first(where: { $0.id == id }) else { return }
    batch.synthesis = synthesis
    try await store.save(batch)
  }

  /// Removes the batches past the retention.
  @discardableResult
  public func prune(now: Date, calendar: Calendar) async -> Int {
    await store.removeBatches(before: ArchiveReportRetention.cutoff(now: now, calendar: calendar))
  }

  public func removeAll() async throws {
    try await store.removeAll()
  }
}
