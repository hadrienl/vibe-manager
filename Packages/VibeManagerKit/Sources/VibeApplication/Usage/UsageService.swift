import Foundation
import VibeDomain

/// What the interface reads usage through: the journal of runs, the tokens the transcripts
/// reported, and the tracking switch. Nothing here reaches the network.
public actor UsageService {
  public nonisolated let recorder: UsageRecorder
  private let ledger: any UsageLedger
  private let tracking: any UsageTrackingStore
  private let tokenStore: any TokenUsageStore
  private let reader: (any TokenUsageReading)?
  private let clock: any SessionClock

  private var snapshot: TokenUsageSnapshot?
  private var isRefreshing = false
  /// Bumped by a clear and by the tracking switch: a reading started before either is dropped,
  /// or it would put back what was just erased, or count what was just switched off.
  private var generation = 0

  public init(
    recorder: UsageRecorder,
    ledger: any UsageLedger,
    tracking: any UsageTrackingStore,
    tokenStore: any TokenUsageStore,
    reader: (any TokenUsageReading)?,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.recorder = recorder
    self.ledger = ledger
    self.tracking = tracking
    self.tokenStore = tokenStore
    self.reader = reader
    self.clock = clock
  }

  /// Reads what the transcripts of these sessions added since the last time. Does nothing while
  /// tracking is off: an agent's usage during that time is not the application's to read.
  @discardableResult
  public func refreshTokens(for sessions: [WorkSession]) async -> Bool {
    guard let reader, !isRefreshing, await recorder.isTracking() else { return false }
    isRefreshing = true
    defer { isRefreshing = false }
    let started = generation
    let current = await loadedSnapshot()
    let intervals = await tracking.intervals()
    let next = await reader.refresh(sessions, from: current, isTracked: { intervals.tracks($0) })
    guard generation == started, next != current else { return false }
    snapshot = next
    try? await tokenStore.save(next)
    return true
  }

  public func tokens() async -> TokenUsageSnapshot {
    await loadedSnapshot()
  }

  /// Every run recorded, the open ones included as they stand now.
  public func runs() async -> [UsageRun] {
    await recorder.prepare()
    let recorded = UsageLedgerFold.runs(from: (try? await ledger.events()) ?? [])
    let open = Dictionary(
      (await recorder.openRuns()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return recorded.map { run in
      guard run.isOpen, var current = open[run.id] else { return run }
      current.suspensions = run.suspensions
      return current
    }
  }

  public func report(
    period: UsagePeriod, grouping: UsageGrouping, calendar: Calendar = .current
  ) async -> UsageReport {
    let now = clock.now()
    return UsageAggregator.report(
      runs: await runs(), tokens: await loadedSnapshot().buckets,
      period: period.interval(now: now, calendar: calendar), grouping: grouping, now: now,
      calendar: calendar)
  }

  /// The whole usage of one session.
  public func sessionReport(_ id: SessionID, calendar: Calendar = .current) async -> UsageRow {
    let now = clock.now()
    let report = UsageAggregator.report(
      runs: await runs().filter { $0.sessionID == id },
      tokens: await loadedSnapshot().buckets.filter { $0.sessionID == id },
      period: nil, grouping: .model, now: now, calendar: calendar)
    return report.total
  }

  public func sessionModels(_ id: SessionID, calendar: Calendar = .current) async -> [UsageRow] {
    let now = clock.now()
    return UsageAggregator.report(
      runs: [], tokens: await loadedSnapshot().buckets.filter { $0.sessionID == id },
      period: nil, grouping: .model, now: now, calendar: calendar
    ).rows
  }

  /// Everything a screen shows, from one reading of the journal: the report for the period, and
  /// the whole usage of each of `sessions`.
  public func overview(
    period: UsagePeriod, grouping: UsageGrouping, sessions: [SessionID],
    calendar: Calendar = .current
  ) async -> UsageOverview {
    let now = clock.now()
    let runs = await runs()
    let tokens = await loadedSnapshot()
    let buckets = tokens.buckets
    let report = UsageAggregator.report(
      runs: runs, tokens: buckets, period: period.interval(now: now, calendar: calendar),
      grouping: grouping, now: now, calendar: calendar)
    let wanted = Set(sessions)
    let runsBySession = Dictionary(grouping: runs.filter { wanted.contains($0.sessionID) }) {
      $0.sessionID
    }
    let bucketsBySession = Dictionary(
      grouping: buckets.filter { wanted.contains($0.sessionID) }
    ) { $0.sessionID }
    var perSession: [SessionID: UsageOverview.Session] = [:]
    for id in sessions {
      let whole = UsageAggregator.report(
        runs: runsBySession[id] ?? [], tokens: bucketsBySession[id] ?? [], period: nil,
        grouping: .model, now: now, calendar: calendar)
      let models = UsageAggregator.report(
        runs: [], tokens: bucketsBySession[id] ?? [], period: nil, grouping: .model, now: now,
        calendar: calendar)
      perSession[id] = UsageOverview.Session(
        total: whole.total, models: models.rows, hasTranscript: tokens.hasTranscript(for: id),
        transcriptMissingSince: tokens.missingSince(for: id))
    }
    return UsageOverview(
      report: report, sessions: perSession, runsRecordedSince: runs.map(\.startedAt).min())
  }

  public func trackingIntervals() async -> [UsageTrackingInterval] {
    await tracking.intervals()
  }

  public func setTracking(_ enabled: Bool) async {
    generation += 1
    await recorder.setTracking(enabled)
  }

  /// Deletes what was recorded and read. The agents' transcripts are left alone, and what they
  /// say about the time before this instant is never read again.
  public func clear() async {
    generation += 1
    await recorder.clear()
    try? await tokenStore.clear()
    snapshot = .empty
  }

  private func loadedSnapshot() async -> TokenUsageSnapshot {
    if let snapshot { return snapshot }
    let loaded = await tokenStore.load()
    snapshot = loaded
    return loaded
  }
}

/// What the usage screens show, read at once.
public struct UsageOverview: Sendable {
  public struct Session: Equatable, Sendable {
    public var total: UsageRow
    /// The tokens by model the CLI said answered.
    public var models: [UsageRow]
    public var hasTranscript: Bool
    /// When a transcript of this session stopped being found, the last time it was read.
    public var transcriptMissingSince: Date?
  }

  public var report: UsageReport
  public var sessions: [SessionID: Session]
  /// When the first run was recorded: running time and runs start there, tokens do not.
  public var runsRecordedSince: Date?
}
