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
  /// `nil` when no reliable source gives it.
  public var windowSize: Int?
  public var measuredAt: Date
  /// Where `windowSize` comes from; `nil` without one.
  public var source: Source?
  public var lastCompaction: Compaction?
  /// Whether the share is computed as Codex computes its own “context left”.
  public var countsLikeCodex: Bool

  public init(
    usedTokens: Int, windowSize: Int? = nil, measuredAt: Date, source: Source? = nil,
    lastCompaction: Compaction? = nil, countsLikeCodex: Bool = false
  ) {
    self.usedTokens = usedTokens
    self.windowSize = windowSize
    self.measuredAt = measuredAt
    self.source = source
    self.lastCompaction = lastCompaction
    self.countsLikeCodex = countsLikeCodex
  }

  /// What Codex keeps for its own instructions and tools, out of both the window and the context
  /// when it says how much is left (codex-rs `TokenUsage::percent_of_context_window_remaining`).
  public static let codexBaselineTokens = 12_000

  /// The share of the window used, from 0 to 100; `nil` without a window.
  public var percentUsed: Int? {
    guard let windowSize, windowSize > 0 else { return nil }
    if countsLikeCodex {
      let baseline = Self.codexBaselineTokens
      guard windowSize > baseline else { return 100 }
      let effective = Double(windowSize - baseline)
      let used = Double(max(usedTokens - baseline, 0))
      let remaining = Int((max(effective - used, 0) / effective * 100).rounded())
      return 100 - min(max(remaining, 0), 100)
    }
    return min(Int((Double(usedTokens) / Double(windowSize) * 100).rounded()), 100)
  }

  /// The window declared by an endpoint wins over the one the CLI reports: the CLI's describes
  /// another model.
  public func declared(by endpoint: String, window: Int?) -> ContextWindowUsage {
    guard let window, window > 0 else { return self }
    var usage = self
    usage.windowSize = window
    usage.source = .declaredByEndpoint(endpoint)
    usage.countsLikeCodex = false
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
