import Foundation
import VibeDomain

public enum ArchiveReportStoreError: Error, Hashable, Sendable {
  case cannotWrite(String)
}

/// Where the batches are kept (#408): one file each, for twelve months.
public protocol ArchiveReportStore: Sendable {
  /// Every batch that reads, the oldest first. A file that does not read is left where it is.
  func batches() async -> [ArchiveBatch]
  func save(_ batch: ArchiveBatch) async throws
  /// Removes the batches older than `date`, and says how many.
  @discardableResult
  func removeBatches(before date: Date) async -> Int
  func removeAll() async throws
}

public enum ArchiveReportRetention {
  /// How long a batch is kept.
  public static let months = 12

  /// Before this, batches are removed.
  public static func cutoff(now: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .month, value: -months, to: now) ?? now
  }
}

/// Batches kept in memory, for tests and previews.
public actor InMemoryArchiveReportStore: ArchiveReportStore {
  private var stored: [UUID: ArchiveBatch]

  public init(batches: [ArchiveBatch] = []) {
    stored = Dictionary(batches.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }

  public func batches() -> [ArchiveBatch] {
    stored.values.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
  }

  public func save(_ batch: ArchiveBatch) {
    stored[batch.id] = batch
  }

  public func removeBatches(before date: Date) -> Int {
    let old = stored.values.filter { $0.date < date }.map(\.id)
    for id in old { stored[id] = nil }
    return old.count
  }

  public func removeAll() {
    stored = [:]
  }
}
