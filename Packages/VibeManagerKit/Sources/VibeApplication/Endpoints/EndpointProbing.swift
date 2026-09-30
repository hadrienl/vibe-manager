import Foundation
import VibeDomain

/// What "Test" found about an endpoint (#107), one check after the other.
///
/// Facts rather than sentences: the settings say them in the user's language. The only text an
/// endpoint gets to put in front of the user is its own error message, shown as its words.
public struct EndpointTestReport: Hashable, Sendable {
  public var model: String
  public var date: Date
  public var checks: [EndpointTestCheck]

  public init(model: String, date: Date, checks: [EndpointTestCheck]) {
    self.model = model
    self.date = date
    self.checks = checks
  }

  public var verdict: EndpointTestOutcome.Verdict {
    if checks.contains(where: \.outcome.isFailure) { return .failed }
    if checks.contains(where: \.outcome.isWarning) { return .passedWithWarnings }
    return .passed
  }
}

public struct EndpointTestCheck: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable, CaseIterable {
    case reachable
    case authentication
    case answer
    case toolCall
    case toolResult
    case usage
  }

  public enum Outcome: Hashable, Sendable {
    case passed
    case warning
    case failed
    /// Not tried: an earlier check failed.
    case skipped

    public var isFailure: Bool { self == .failed }
    public var isWarning: Bool { self == .warning }
  }

  public var kind: Kind
  public var outcome: Outcome
  public var detail: EndpointTestDetail?

  public init(kind: Kind, outcome: Outcome, detail: EndpointTestDetail? = nil) {
    self.kind = kind
    self.outcome = outcome
    self.detail = detail
  }

  public var id: Kind { kind }
}

public enum EndpointTestDetail: Hashable, Sendable {
  /// How long the endpoint took to answer, in milliseconds.
  case latency(milliseconds: Int)
  /// The first words after that long, then that many tokens a second when the endpoint said.
  case speed(firstTokenMilliseconds: Int, tokensPerSecond: Double?)
  /// The endpoint's own words.
  case endpointSaid(status: Int?, message: String)
  case unreachable
  case timedOut
  case refusedKey
  case noToolCall
  case invalidArguments
  case noAnswerAfterTool
  case noUsage
  /// Steps an agent on the server ran by itself.
  case serverSteps(count: Int)
}

public enum EndpointDiscoveryError: Error, Equatable, Sendable {
  case failed(EndpointTestDetail)
  /// The endpoint answered, but with no list of models Vibe Manager can read: they are typed.
  case noList
}

/// Talks to an endpoint on behalf of the settings: its models, and a test of one of them. The
/// secret is given rather than read, so an endpoint can be tried before it is saved.
public protocol EndpointProbing: Sendable {
  func discoverModels(for endpoint: Endpoint, secret: String?) async throws -> [EndpointModel]
  func test(_ endpoint: Endpoint, secret: String?, model: String) async -> EndpointTestReport
}
