import Foundation
import VibeDomain

/// Which request, among every session's: the session, and a key its agent's reports make unique —
/// the line of the activity log that carried it, or the call the agent's own journal names.
public struct AgentRequestID: Hashable, Codable, Sendable {
  public let sessionID: SessionID
  public let key: String

  public init(sessionID: SessionID, key: String) {
    self.sessionID = sessionID
    self.key = key
  }
}

/// Something an agent stopped to ask the user (#40): a permission, questions, a plan.
///
/// Read from what the agent's hooks reported, never from its screen. Everything in it came from
/// the agent — and so from whatever a repository, a page or a server made it write: it is shown,
/// never interpreted.
public struct AgentRequest: Identifiable, Hashable, Codable, Sendable {
  public let id: AgentRequestID
  public let receivedAt: Date
  public let kind: AgentQuestionKind
  public var content: AgentRequestContent
  /// The tool the request holds up, for telling which request a tool finishing settles.
  public var reference: AgentToolReference
  /// Whether the CLI reported it once its dialog was drawn. Before that, a keystroke meant for the
  /// dialog lands in the prompt — seen in the spike of #40, where the Return that followed then
  /// picked the highlighted option: the wrong one.
  public var isShown: Bool

  public init(
    id: AgentRequestID,
    receivedAt: Date,
    kind: AgentQuestionKind,
    content: AgentRequestContent,
    reference: AgentToolReference,
    isShown: Bool
  ) {
    self.id = id
    self.receivedAt = receivedAt
    self.kind = kind
    self.content = content
    self.reference = reference
    self.isShown = isShown
  }
}

/// What a request asks.
public enum AgentRequestContent: Hashable, Codable, Sendable {
  case permission(AgentToolPermission)
  /// One or several questions, asked together.
  case questions([AgentQuestion])
  /// A plan to accept before the agent starts. `excerpt` is its beginning.
  case plan(excerpt: String, isComplete: Bool)
  /// A form an MCP server asks the user to fill in: only the terminal can.
  case elicitation
  /// The agent asked something its report does not let us read: cut short, or not JSON.
  case unreadable(tool: String?)

  public var isUnreadable: Bool {
    if case .unreadable = self { return true }
    return false
  }
}

/// A tool the agent wants to run.
public struct AgentToolPermission: Hashable, Codable, Sendable {
  public enum Tool: Hashable, Codable, Sendable {
    case shell
    case edit
    case write
    case read
    case web
    case patch
    case mcp(server: String, tool: String)
    case other(String)
  }

  public let tool: Tool
  /// The tool's name as the agent gave it: `Bash`, `apply_patch`, `mcp__github__create_issue`.
  public let toolName: String
  /// What decides whether to allow it — the exact command, the file, the address — in full.
  public let subject: String?
  /// The agent's own words for what the call is for, when it gave some.
  public let purpose: String?
  /// Everything the tool was handed, laid out as it came, for "Show all".
  public let details: String?
  public let workingDirectory: String?
  /// The broader permission the CLI offers beside "allow once", when it offers one.
  public let alwaysAllow: AgentAlwaysAllow?
  /// `false` when the report was cut short: what would be allowed cannot all be seen.
  public let isComplete: Bool

  public init(
    tool: Tool,
    toolName: String,
    subject: String?,
    purpose: String? = nil,
    details: String? = nil,
    workingDirectory: String? = nil,
    alwaysAllow: AgentAlwaysAllow? = nil,
    isComplete: Bool = true
  ) {
    self.tool = tool
    self.toolName = toolName
    self.subject = subject
    self.purpose = purpose
    self.details = details
    self.workingDirectory = workingDirectory
    self.alwaysAllow = alwaysAllow
    self.isComplete = isComplete
  }
}

/// What "always allow" would allow, in the CLI's own terms.
public struct AgentAlwaysAllow: Hashable, Codable, Sendable {
  public enum Rule: Hashable, Codable, Sendable {
    /// Access to these folders.
    case directories([String])
    /// A permission rule, as `Bash(npm test:*)`.
    case toolRule(tool: String, content: String?)
    /// A permission mode: `acceptEdits`…
    case mode(String)
    /// Commands starting like this one — Codex picks the prefix itself.
    case commandPrefix
    /// These files, for the rest of the session.
    case files
  }

  /// Where the CLI keeps what is allowed.
  public enum Scope: String, Hashable, Codable, Sendable {
    case session, project, user
  }

  public let rules: [Rule]
  public let scope: Scope

  public init(rules: [Rule], scope: Scope) {
    self.rules = rules
    self.scope = scope
  }
}

public struct AgentQuestion: Hashable, Codable, Sendable {
  public struct Option: Hashable, Codable, Sendable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
      self.label = label
      self.description = description
    }
  }

  public let header: String?
  public let text: String
  public let options: [Option]
  public let allowsMultipleChoices: Bool
  public let allowsFreeText: Bool

  public init(
    header: String?,
    text: String,
    options: [Option],
    allowsMultipleChoices: Bool = false,
    allowsFreeText: Bool = true
  ) {
    self.header = header
    self.text = text
    self.options = options
    self.allowsMultipleChoices = allowsMultipleChoices
    self.allowsFreeText = allowsFreeText
  }
}

/// Which tool call a report is about, for matching a request with the tool that settles it. The
/// CLIs give a permission no call identifier: the tool, the agent that runs it — sub-agents run
/// side by side — and what it works on are what tells two apart.
public struct AgentToolReference: Hashable, Codable, Sendable {
  public let tool: String?
  public let agentID: String?
  public let subject: String?

  public init(tool: String?, agentID: String? = nil, subject: String? = nil) {
    self.tool = tool
    self.agentID = agentID
    self.subject = subject
  }

  public enum Match: Sendable {
    case same
    /// Same tool and agent, but what it works on cannot be compared: one side does not say.
    case likely
    case different
  }

  public func match(_ other: AgentToolReference) -> Match {
    guard tool == other.tool, agentID == other.agentID else { return .different }
    switch (subject, other.subject) {
    case (nil, nil): return .same
    case (let mine?, let theirs?): return mine == theirs ? .same : .different
    default: return .likely
    }
  }
}

/// What a decoder read from a report that asks the user something.
public struct AgentRequestNotice: Hashable, Sendable {
  public let content: AgentRequestContent
  public let reference: AgentToolReference
  /// Reported once its dialog is drawn (`PermissionRequest`), or before (`PreToolUse`).
  public let isShown: Bool
  /// A key of the agent's own for the request, when its journal gives one. Otherwise the line of
  /// the log that carried it is the key.
  public let key: String?

  public init(
    content: AgentRequestContent,
    reference: AgentToolReference,
    isShown: Bool,
    key: String? = nil
  ) {
    self.content = content
    self.reference = reference
    self.isShown = isShown
    self.key = key
  }
}

// MARK: - Answers

/// An answer to a request, as the user gives it in the palette.
public enum AgentAnswer: Hashable, Sendable {
  case allowOnce
  case allowAlways
  case deny
  /// One answer per question, in order.
  case answers([AgentQuestionAnswer])
  case approvePlan(AgentPlanApproval)
  case rejectPlan
}

extension AgentAnswer {
  /// What the palette must offer for this answer to be given.
  public var requiredKinds: Set<AgentAnswerKind> {
    switch self {
    case .allowOnce: return [.allowOnce]
    case .allowAlways: return [.allowAlways]
    case .deny: return [.deny]
    case .approvePlan: return [.approvePlan]
    case .rejectPlan: return [.rejectPlan]
    case .answers(let answers):
      return Set(
        answers.map { answer -> AgentAnswerKind in
          switch answer {
          case .option: return .chooseOption
          case .options: return .chooseOptions
          case .text: return .writeText
          }
        })
    }
  }
}

public enum AgentQuestionAnswer: Hashable, Sendable {
  /// The option at this index.
  case option(Int)
  /// These options, for a question that takes several.
  case options(Set<Int>)
  case text(String)
}

public enum AgentPlanApproval: Hashable, Sendable {
  /// The agent's edits are accepted as they come.
  case acceptEdits
  /// Each edit asks first.
  case reviewEdits
}

/// Why a request is answered in its terminal only.
public enum AgentRequestTerminalReason: Hashable, Sendable {
  /// Its dialog is not drawn yet, or the CLI never says when it is.
  case notYetShown
  /// Another request of the session comes first.
  case queued
  /// Which of the session's dialogs is drawn is not known for sure: requests arrived together,
  /// or a tool settled that may have been this one's.
  case uncertain
  /// What would be allowed was cut short.
  case truncated
  /// The CLI's dialog for it cannot be driven from outside.
  case notSupported
}

/// How a request can be answered right now.
public enum AgentRequestAnswering: Hashable, Sendable {
  case fromPalette(Set<AgentAnswerKind>)
  case inTerminalOnly(AgentRequestTerminalReason)

  public var answers: Set<AgentAnswerKind> {
    if case .fromPalette(let kinds) = self { return kinds }
    return []
  }
}

/// The answers a palette offers, without their values.
public enum AgentAnswerKind: Hashable, Sendable {
  case allowOnce, allowAlways, deny
  case chooseOption, chooseOptions, writeText
  case approvePlan, rejectPlan
}

/// Types an answer into the terminal of one CLI, keystroke by keystroke, as the user would (#40).
///
/// Each CLI's dialogs are its own: which digit takes which option, how a free answer is entered,
/// which key refuses. The keys were taken down in the spike of #40, and fixtures pin them.
public protocol AgentAnswerKeymap: Sendable {
  /// What this CLI's dialog for the request lets be answered from outside.
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind>
  /// The writes that give the answer, one per step: between two, the terminal settles. `nil` when
  /// this answer cannot be given to this request.
  func keystrokes(for answer: AgentAnswer, to content: AgentRequestContent) -> [[UInt8]]?
}

extension AgentActivityState {
  /// How `request` can be answered now: only the first of the queue can, once its dialog is drawn
  /// and nothing has put in doubt which dialog is.
  public func answering(
    _ request: AgentRequest,
    keymap: (any AgentAnswerKeymap)?
  ) -> AgentRequestAnswering {
    guard let keymap else { return .inTerminalOnly(.notSupported) }
    guard requests.first?.id == request.id else { return .inTerminalOnly(.queued) }
    guard request.isShown else { return .inTerminalOnly(.notYetShown) }
    guard !isFirstRequestUncertain else { return .inTerminalOnly(.uncertain) }
    var kinds = keymap.answers(for: request.content)
    if case .permission(let permission) = request.content, !permission.isComplete {
      // What would be allowed is not all on screen: it may only be refused (#40, decision 2).
      kinds.subtract([.allowOnce, .allowAlways])
      if kinds.isEmpty { return .inTerminalOnly(.truncated) }
    }
    return kinds.isEmpty ? .inTerminalOnly(.notSupported) : .fromPalette(kinds)
  }
}

// MARK: - Keystrokes

/// The bytes a terminal interface reads as keys.
public enum TerminalKeys {
  public static let escape: [UInt8] = [0x1B]
  public static let enter: [UInt8] = [0x0D]
  public static let rightArrow: [UInt8] = [0x1B, 0x5B, 0x43]

  /// The digit that picks the option at `index`, when one digit can.
  public static func digit(forOption index: Int) -> [UInt8]? {
    guard (0..<9).contains(index) else { return nil }
    return [UInt8(0x31 + index)]
  }

  /// Text pasted rather than typed: a newline in it stays text instead of sending the line. Every
  /// control character but newline and tab is taken out first, the escape that could close the
  /// paste early above all.
  public static func bracketedPaste(_ text: String) -> [UInt8] {
    let kept = text.unicodeScalars.filter { scalar in
      scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control)
    }
    let cleaned = String(String.UnicodeScalarView(kept))
    return [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(cleaned.utf8)
      + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
  }
}
