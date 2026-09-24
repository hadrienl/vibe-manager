import Foundation
import VibeDomain

/// One line of the run journal. Nothing in it says what an agent was asked or answered.
public enum UsageLedgerEvent: Hashable, Sendable {
  case start(UsageRun)
  case end(runID: UUID, at: Date, exit: UsageRunExit)
  /// The application quit and left the run in the terminal host.
  case detach(runID: UUID, at: Date)
  /// The next launch found it still running in the host, and took it back.
  case attach(runID: UUID, at: Date)
  /// The Mac went to sleep, and woke up. Every run open at that moment is concerned.
  case suspend(at: Date)
  case resume(at: Date)

  public var date: Date {
    switch self {
    case .start(let run): return run.startedAt
    case .end(_, let at, _), .detach(_, let at), .attach(_, let at): return at
    case .suspend(let at), .resume(let at): return at
    }
  }
}

/// What the application was running a moment ago, rewritten every minute while anything runs.
///
/// A run the journal never saw end is closed at the last heartbeat that names it: an application
/// that crashed loses at most one interval of running time, never a night.
public struct UsageHeartbeat: Hashable, Codable, Sendable {
  public var at: Date
  public var runIDs: [UUID]

  public init(at: Date, runIDs: [UUID]) {
    self.at = at
    self.runIDs = runIDs
  }
}

/// The run journal: appended to, read back whole, and cleared.
public protocol UsageLedger: Sendable {
  func append(_ event: UsageLedgerEvent) async throws
  func events() async throws -> [UsageLedgerEvent]
  func writeHeartbeat(_ heartbeat: UsageHeartbeat?) async throws
  func heartbeat() async -> UsageHeartbeat?
  func clear() async throws
}

/// When tracking was on.
public protocol UsageTrackingStore: Sendable {
  func intervals() async -> [UsageTrackingInterval]
  func save(_ intervals: [UsageTrackingInterval]) async throws
}

/// The token totals read so far, and where each transcript was left.
public protocol TokenUsageStore: Sendable {
  func load() async -> TokenUsageSnapshot
  func save(_ snapshot: TokenUsageSnapshot) async throws
  func clear() async throws
}

/// Reads the token usage the agents' own transcripts carry.
public protocol TokenUsageReading: Sendable {
  /// Reads what was added to the sessions' transcripts since `snapshot`, keeping only what
  /// `isTracked` accepts, and answers the snapshot to keep.
  func refresh(
    _ sessions: [WorkSession],
    from snapshot: TokenUsageSnapshot,
    isTracked: @escaping @Sendable (Date) -> Bool
  ) async -> TokenUsageSnapshot
}

/// Folds the journal into runs.
public enum UsageLedgerFold {
  public static func runs(from events: [UsageLedgerEvent]) -> [UsageRun] {
    var runs: [UUID: UsageRun] = [:]
    var order: [UUID] = []
    var sleepingSince: Date?
    var sleeps: [DateInterval] = []
    for event in events {
      switch event {
      case .start(let run):
        // A sleep never seen to end — the Mac lost power asleep, or the application died with it —
        // has no end to take out: forgotten rather than stretched to the next wake.
        sleepingSince = nil
        if runs[run.id] == nil { order.append(run.id) }
        runs[run.id] = run
      case .end(let id, let at, let exit):
        guard var run = runs[id], run.endedAt == nil else { continue }
        run.endedAt = max(at, run.startedAt)
        run.exit = exit
        runs[id] = run
      case .detach(let id, let at):
        runs[id]?.detachedAt = at
      case .attach(let id, _):
        runs[id]?.detachedAt = nil
      case .suspend(let at):
        // A second sleep before a wake: the first one's end was lost, and it is dropped.
        sleepingSince = at
      case .resume(let at):
        if let start = sleepingSince, at > start {
          sleeps.append(DateInterval(start: start, end: at))
        }
        sleepingSince = nil
      }
    }
    return order.compactMap { id in
      guard var run = runs[id] else { return nil }
      let end = run.endedAt ?? .distantFuture
      run.suspensions = sleeps.filter { $0.end > run.startedAt && $0.start < end }
      return run
    }
  }
}

// MARK: - Token snapshot

/// Where one transcript file was left, and what it has reported.
public struct TokenUsageFile: Hashable, Codable, Sendable {
  public struct Tally: Hashable, Codable, Sendable {
    public var model: String
    public var day: LocalDay
    public var tokens: TokenCounts
    public var responses: Int

    public init(model: String, day: LocalDay, tokens: TokenCounts = .zero, responses: Int = 0) {
      self.model = model
      self.day = day
      self.tokens = tokens
      self.responses = responses
    }
  }

  public var sessionID: SessionID
  public var providerID: String
  public var inode: UInt64?
  public var offset: UInt64
  /// The last response identifiers counted: the CLIs write one response over several lines.
  public var recentResponseIDs: [String]
  /// The model named by the last turn read, for a CLI that names it once per turn (Codex).
  public var currentModel: String?
  /// The running total of the last per-turn event counted: an older Codex repeats the event,
  /// total included, when only its rate limits changed.
  public var lastFallbackTotal: TokenCounts?
  /// Counted from per-response records.
  public var tallies: [Tally]
  /// Counted from the per-turn fallback of an older CLI, used only when there is no record.
  public var fallbackTallies: [Tally]
  public var lastReadAt: Date?
  /// The CLI deleted the file. What it reported is kept.
  public var isMissing: Bool

  public init(
    sessionID: SessionID, providerID: String, inode: UInt64? = nil, offset: UInt64 = 0,
    recentResponseIDs: [String] = [], currentModel: String? = nil, tallies: [Tally] = [],
    fallbackTallies: [Tally] = [], lastReadAt: Date? = nil, isMissing: Bool = false
  ) {
    self.sessionID = sessionID
    self.providerID = providerID
    self.inode = inode
    self.offset = offset
    self.recentResponseIDs = recentResponseIDs
    self.currentModel = currentModel
    self.tallies = tallies
    self.fallbackTallies = fallbackTallies
    self.lastReadAt = lastReadAt
    self.isMissing = isMissing
  }

  /// What the file counts: its records, or its fallback when it has none.
  public var effectiveTallies: [Tally] {
    tallies.isEmpty ? fallbackTallies : tallies
  }

  public static let recentLimit = 64

  /// Whether a response was already counted, and remembers it otherwise.
  public mutating func isFirstSighting(of responseID: String) -> Bool {
    guard !recentResponseIDs.contains(responseID) else { return false }
    recentResponseIDs.append(responseID)
    if recentResponseIDs.count > Self.recentLimit {
      recentResponseIDs.removeFirst(recentResponseIDs.count - Self.recentLimit)
    }
    return true
  }

  public mutating func add(_ tokens: TokenCounts, model: String, day: LocalDay, fallback: Bool) {
    func add(to list: inout [Tally]) {
      if let index = list.firstIndex(where: { $0.model == model && $0.day == day }) {
        list[index].tokens += tokens
        list[index].responses += 1
      } else {
        list.append(Tally(model: model, day: day, tokens: tokens, responses: 1))
      }
    }
    if fallback { add(to: &fallbackTallies) } else { add(to: &tallies) }
  }
}

/// Every transcript read so far, keyed by a digest of its path — a Claude Code project folder is
/// named after the repository it ran in. Only counters: no line of a transcript is ever kept.
public struct TokenUsageSnapshot: Hashable, Codable, Sendable {
  public var files: [String: TokenUsageFile]

  public init(files: [String: TokenUsageFile] = [:]) {
    self.files = files
  }

  public static let empty = TokenUsageSnapshot()

  public var buckets: [TokenUsageBucket] {
    var merged: [String: TokenUsageBucket] = [:]
    for file in files.values {
      for tally in file.effectiveTallies {
        let key = "\(file.sessionID)|\(file.providerID)|\(tally.model)|\(tally.day)"
        if var bucket = merged[key] {
          bucket.tokens += tally.tokens
          bucket.responses += tally.responses
          merged[key] = bucket
        } else {
          merged[key] = TokenUsageBucket(
            sessionID: file.sessionID, providerID: file.providerID, model: tally.model,
            day: tally.day, tokens: tally.tokens, responses: tally.responses)
        }
      }
    }
    return Array(merged.values)
  }

  /// Whether a transcript of this session has ever been found.
  public func hasTranscript(for session: SessionID) -> Bool {
    files.values.contains { $0.sessionID == session }
  }

  /// When the CLI deleted a transcript of this session, what was last read of it.
  public func missingSince(for session: SessionID) -> Date? {
    files.values.filter { $0.sessionID == session && $0.isMissing }.compactMap(\.lastReadAt).max()
  }
}
