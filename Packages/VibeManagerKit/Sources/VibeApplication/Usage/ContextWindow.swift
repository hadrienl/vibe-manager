import Foundation
import VibeDomain

/// How much of its context window the current conversation of a session fills (#407): the
/// context of its last answer, as the CLI counts it.
///
/// A value of the moment, never written to disk: it is read again from the transcript.
public struct ContextWindowUsage: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    /// The CLI wrote the window beside the tokens (Codex).
    case reportedByCLI
    /// The endpoint the conversation went through declared it, named here.
    case declaredByEndpoint(String)
  }

  public struct Compaction: Hashable, Sendable {
    public var date: Date
    /// The context before the compaction, when the CLI says it.
    public var tokensBefore: Int?

    public init(date: Date, tokensBefore: Int? = nil) {
      self.date = date
      self.tokensBefore = tokensBefore
    }
  }

  public var usedTokens: Int
  /// `nil` when no source gives it.
  public var windowSize: Int?
  /// When the CLI compacts the conversation on its own: what the share is measured against.
  public var compactionThreshold: Int?
  /// The window and threshold are deduced from the model, not reported.
  public var isEstimate: Bool
  /// The model the window was deduced from.
  public var model: String?
  public var measuredAt: Date
  /// Where `windowSize` comes from; `nil` without one.
  public var source: Source?
  public var lastCompaction: Compaction?

  public init(
    usedTokens: Int, windowSize: Int? = nil, compactionThreshold: Int? = nil,
    isEstimate: Bool = false, model: String? = nil, measuredAt: Date, source: Source? = nil,
    lastCompaction: Compaction? = nil
  ) {
    self.usedTokens = usedTokens
    self.windowSize = windowSize
    self.compactionThreshold = compactionThreshold
    self.isEstimate = isEstimate
    self.model = model
    self.measuredAt = measuredAt
    self.source = source
    self.lastCompaction = lastCompaction
  }

  /// The share of the way to the automatic compaction, from 0 to 100 — of the window when the
  /// threshold is unknown; `nil` without either.
  public var percentUsed: Int? {
    guard let limit = compactionThreshold ?? windowSize, limit > 0 else { return nil }
    return min(Int((Double(usedTokens) / Double(limit) * 100).rounded()), 100)
  }

  // MARK: - The CLIs' own rules

  /// Codex compacts at nine tenths of the window when its model catalogue sets no limit
  /// (`auto_compact_token_limit`), as every model of Codex 0.164's does.
  public static func codexCompactionThreshold(window: Int) -> Int {
    window * 9 / 10
  }

  /// Claude Code 2.1 compacts at its window, less the output it keeps for the answer (at most
  /// 20 000) and a margin of 13 000.
  public static func claudeCompactionThreshold(window: Int) -> Int {
    max(window - claudeOutputReserve - claudeCompactionMargin, 0)
  }

  static let claudeOutputReserve = 20_000
  static let claudeCompactionMargin = 13_000
  public static let claudeDefaultWindow = 200_000
  public static let claudeLongWindow = 1_000_000

  /// The window of a Claude model: a million for its `[1m]` variant, or when the conversation
  /// already went past the default; 200 000 otherwise.
  public static func claudeWindow(model: String?, seen tokens: Int) -> Int {
    if model?.hasSuffix("[1m]") == true || tokens > claudeDefaultWindow {
      return claudeLongWindow
    }
    return claudeDefaultWindow
  }

  /// The window declared by an endpoint wins over the one the CLI reports or the one deduced:
  /// they describe another model. The CLI is told to compact by it at launch (ADR 0035).
  public func declared(by endpoint: String, window: Int?, harnessIsCodex: Bool)
    -> ContextWindowUsage
  {
    guard let window, window > 0 else { return self }
    var usage = self
    usage.windowSize = window
    usage.compactionThreshold =
      harnessIsCodex
      ? Self.codexCompactionThreshold(window: window)
      : Self.claudeCompactionThreshold(window: window)
    usage.isEstimate = false
    usage.source = .declaredByEndpoint(endpoint)
    return usage
  }
}

/// Why a session shows no context.
public enum ContextWindowUnavailability: Hashable, Sendable {
  case trackingOff
  /// The agent writes nothing the application can read: the mock, an agent of its own.
  case notReportedByAgent
  /// No answer was read yet in the current conversation.
  case noResponseYet
}

/// Where one transcript was left, for the context alone. Kept in memory only.
public struct ContextWindowFile: Hashable, Sendable {
  public var inode: UInt64?
  public var offset: UInt64
  public var usage: ContextWindowUsage?
  /// A compaction read after the last answer, for the next one to carry.
  public var compaction: ContextWindowUsage.Compaction?
  /// The model the CLI said it runs, the last time it said it (Claude Code).
  public var model: String?

  public init(inode: UInt64? = nil, offset: UInt64 = 0) {
    self.inode = inode
    self.offset = offset
  }
}

/// Reads the context of the current conversation of a session from its transcript.
public protocol ContextWindowReading: Sendable {
  /// What `conversation` reported since `file`, and the state to keep; `nil` when the agent
  /// writes no transcript the application reads, or none is found.
  func readContext(
    of conversation: SessionAgentConfiguration, session: WorkSession, from file: ContextWindowFile?
  ) async -> ContextWindowFile?
}
