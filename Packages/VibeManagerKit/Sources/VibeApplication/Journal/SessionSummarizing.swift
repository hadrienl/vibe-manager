import Foundation
import VibeDomain

/// What a summary pass hands the session's agent.
public struct SummaryRequest: Hashable, Sendable {
  /// The condensed turns, as `TurnDigest` wrote them.
  public let digest: String
  /// How many turns the digest numbers, from 1.
  public let turnCount: Int
  /// The language to write in: `fr-FR`, `en-US`.
  public let language: String

  public init(digest: String, turnCount: Int, language: String) {
    self.digest = digest
    self.turnCount = turnCount
    self.language = language
  }
}

/// One new line of the summary, and which turn of the digest it describes.
public struct SummaryEntry: Hashable, Sendable {
  public let text: String
  /// From 1.
  public let turn: Int

  public init(text: String, turn: Int) {
    self.text = text
    self.turn = turn
  }
}

public enum SummaryError: Error, Hashable, Sendable {
  /// The agent cannot summarize, and will not until something changes on this Mac.
  case unavailable(JournalSummaryUnavailability)
  /// This pass failed; the next may not.
  case failed(String)
}

/// Writes the summary of a session's turns: the same CLI as the session's agent, the same account,
/// in a process of its own that never touches the conversation (#36).
public protocol SessionSummarizing: Sendable {
  func summarize(_ request: SummaryRequest) async throws -> [SummaryEntry]
}

/// An agent provider that can summarize, on the model of `AgentLaunchObserverProviding`.
public protocol SessionSummarizingProviding: Sendable {
  func sessionSummarizer() -> any SessionSummarizing
}

/// Which summarizer answers for an agent. `nil`: that agent cannot summarize.
public protocol SessionSummarizerResolving: Sendable {
  func summarizer(for providerID: String) async -> (any SessionSummarizing)?
}

/// The summarizers of the registered agents.
public struct AgentSessionSummarizers: SessionSummarizerResolving {
  private let agents: any AgentProviderResolving

  public init(agents: any AgentProviderResolving) {
    self.agents = agents
  }

  public func summarizer(for providerID: String) async -> (any SessionSummarizing)? {
    guard let provider = await agents.provider(id: AgentProviderID(providerID)),
      let summarizing = provider as? any SessionSummarizingProviding
    else { return nil }
    return summarizing.sessionSummarizer()
  }
}

/// The instructions and the answer's shape, the same for every CLI.
public enum SummaryInstructions {
  public static let maximumEntries = 5
  public static let maximumLength = 100

  public static func systemPrompt(language: String) -> String {
    """
    You keep the journal of a coding agent's work session. You are given what happened since the \
    journal was last written: numbered turns, each with what the user asked, the tools the agent \
    ran and what it said last, then the resources it used and the latest journal entries.

    Write from 1 to \(maximumEntries) new journal entries: short actions in the past tense, at most \
    \(maximumLength) characters each, in chronological order, such as "Reviewed <url>", \
    "Fixed the failing test", "Pushed the branch". Do not repeat an entry already in the journal. \
    When an entry is about a listed resource, include its exact URL. Give each entry the number of \
    the turn it describes. Write in the language whose BCP 47 tag is \(language). \
    Answer with the JSON object only.
    """
  }

  /// The answer's JSON schema. No length constraint: not every CLI accepts one, and the lengths
  /// are checked when the answer is read.
  public static let schema = """
    {"type":"object","properties":{"entries":{"type":"array","items":{"type":"object",\
    "properties":{"text":{"type":"string"},"turn":{"type":"integer"}},\
    "required":["text","turn"],"additionalProperties":false}}},\
    "required":["entries"],"additionalProperties":false}
    """

  /// The entries of an answer, or why it cannot be used. An answer that is empty, not of the
  /// schema or longer than asked is a failed pass: nothing is added.
  public static func entries(from object: Any, turnCount: Int) throws -> [SummaryEntry] {
    guard let root = object as? [String: Any], let items = root["entries"] as? [[String: Any]]
    else { throw SummaryError.failed("not of the schema") }
    guard !items.isEmpty, items.count <= maximumEntries else {
      throw SummaryError.failed("\(items.count) entries")
    }
    return try items.map { item in
      guard let raw = item["text"] as? String else { throw SummaryError.failed("no text") }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      // A little over is kept whole — a URL cut in half links nowhere — far over is an answer
      // that did not follow the instructions.
      guard !text.isEmpty, text.count <= maximumLength * 2 else {
        throw SummaryError.failed("entry of \(text.count) characters")
      }
      let turn = (item["turn"] as? Int) ?? turnCount
      return SummaryEntry(text: text, turn: min(max(turn, 1), max(turnCount, 1)))
    }
  }
}
