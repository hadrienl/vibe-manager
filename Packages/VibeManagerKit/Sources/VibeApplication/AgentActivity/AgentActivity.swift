import Foundation

/// What a question from an agent is waiting for.
///
/// Told apart because the terminal answers them differently: a single key settles a permission,
/// while a question may take a sentence, and reading its first letter as the answer would clear
/// the question before it has been answered.
public enum AgentQuestionKind: String, Codable, Hashable, Sendable {
  /// A tool the agent wants to run, a plan to accept: yes or no.
  case approval
  /// Something the agent asked the user, among options or in free text.
  case question
}

/// What the agent of a session is doing, as far as anything it said can tell.
public enum AgentActivity: Hashable, Sendable {
  /// Waiting for an instruction. Nothing to read, nothing to answer.
  case idle
  /// Generating, running a tool, running a sub-agent.
  case working
  /// Stopped until the user answers.
  case awaitingUser(AgentQuestionKind)
}

extension AgentActivity: Codable {
  /// Written as one flat word — `idle`, `working`, `awaitingUser.approval` — so the document
  /// holding it reads like the ticket that describes it.
  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case "idle": self = .idle
    case "working": self = .working
    case "awaitingUser.approval": self = .awaitingUser(.approval)
    case "awaitingUser.question": self = .awaitingUser(.question)
    default:
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: value))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .idle: try container.encode("idle")
    case .working: try container.encode("working")
    case .awaitingUser(let kind): try container.encode("awaitingUser.\(kind.rawValue)")
    }
  }
}

/// One thing an agent reported about itself, already translated out of its CLI's own words.
public enum AgentSignal: Hashable, Sendable {
  /// The agent's hooks are wired: from now on, what it says can be believed.
  case channelConfirmed
  /// A turn started. `byUser` is false when the agent resumed on its own — a background task
  /// finishing hands Claude Code a message nobody typed — which must not count as a reading.
  case promptSubmitted(byUser: Bool)
  /// `tool` names the tool the question holds up, when it is known; `notice` is the question
  /// itself, when the report could be read (#40).
  case questionAsked(AgentQuestionKind, tool: String? = nil, notice: AgentRequestNotice? = nil)
  /// The question is behind it: a tool ran, a permission was refused, an answer came back.
  case questionResolved
  /// This tool ran, or was refused: the question it held up, if any, is behind it — but not one
  /// another tool is still waiting on. `agentID` and `subject` tell which call it was, when the
  /// report says: sub-agents run the same tools side by side.
  case toolFinished(String, agentID: String? = nil, subject: String? = nil)
  /// The agent finished its answer.
  case turnEnded
  /// The user stopped the turn. Nothing was answered, so nothing is left to read.
  case interrupted
  /// The agent says it has been waiting for input for a while — the net under an interruption
  /// that went unreported.
  case waitingForInput
  case agentEnded
}

/// One line of an agent's activity log, as its hook wrote it.
public struct AgentActivityEvent: Hashable, Sendable {
  /// The hook's own name for what happened: `Stop`, `PermissionRequest`…
  public let name: String
  public let date: Date
  /// The JSON the hook received, when that hook keeps it. Possibly cut short, and then not JSON.
  public let payload: Data?

  public init(name: String, date: Date, payload: Data? = nil) {
    self.name = name
    self.date = date
    self.payload = payload
  }
}
