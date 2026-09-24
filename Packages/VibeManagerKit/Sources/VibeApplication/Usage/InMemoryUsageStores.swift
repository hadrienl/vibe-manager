import Foundation
import VibeDomain

/// The run journal in memory, for tests and previews.
public actor InMemoryUsageLedger: UsageLedger {
  private var stored: [UsageLedgerEvent] = []
  private var lastHeartbeat: UsageHeartbeat?

  public init(events: [UsageLedgerEvent] = [], heartbeat: UsageHeartbeat? = nil) {
    stored = events
    lastHeartbeat = heartbeat
  }

  public func append(_ event: UsageLedgerEvent) {
    stored.append(event)
  }

  public func events() -> [UsageLedgerEvent] {
    stored
  }

  public func writeHeartbeat(_ heartbeat: UsageHeartbeat?) {
    lastHeartbeat = heartbeat
  }

  public func heartbeat() -> UsageHeartbeat? {
    lastHeartbeat
  }

  public func clear() {
    stored.removeAll()
    lastHeartbeat = nil
  }
}

public actor InMemoryUsageTrackingStore: UsageTrackingStore {
  private var stored: [UsageTrackingInterval]

  public init(intervals: [UsageTrackingInterval] = [UsageTrackingInterval(from: .distantPast)]) {
    stored = intervals
  }

  public func intervals() -> [UsageTrackingInterval] {
    stored
  }

  public func save(_ intervals: [UsageTrackingInterval]) {
    stored = intervals
  }
}

public actor InMemoryTokenUsageStore: TokenUsageStore {
  private var stored: TokenUsageSnapshot

  public init(snapshot: TokenUsageSnapshot = .empty) {
    stored = snapshot
  }

  public func load() -> TokenUsageSnapshot {
    stored
  }

  public func save(_ snapshot: TokenUsageSnapshot) {
    stored = snapshot
  }

  public func clear() {
    stored = .empty
  }
}
