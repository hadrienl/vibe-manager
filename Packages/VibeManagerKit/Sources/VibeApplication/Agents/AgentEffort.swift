import Foundation

/// A level of reasoning effort, as the agents name it (#411): `low`, `high`, `xhigh`…
///
/// Kept as the agent's own word rather than a closed list: each CLI has its levels, Codex's depend
/// on the model, and a newer release may add one.
public enum AgentEffortLevel {
  /// The level as it can go on a command line — a short lowercase word — or `nil` for anything
  /// else, which is never passed: the agent's own default applies instead.
  public static func argument(_ value: String) -> String? {
    guard (1...32).contains(value.utf8.count),
      value.utf8.first.map({ (97...122).contains($0) }) == true,
      value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
    else { return nil }
    return value
  }
}

/// What the agent of a session says of its effort, read from what it wrote.
public struct AgentEffortReport: Equatable, Sendable {
  /// The level the conversation said it last ran with, `nil` when it has not said yet.
  public var effort: String?
  /// The level of the agent's own settings, which a launch given none starts with.
  public var configuredEffort: String?
  /// The model it runs, which decides the levels it takes; `nil` when it does not say.
  public var modelID: String?
  /// When the conversation said `effort`: a level given since is not known to it yet.
  public var saidAt: Date?

  public init(
    effort: String? = nil, configuredEffort: String? = nil, modelID: String? = nil,
    saidAt: Date? = nil
  ) {
    self.effort = effort
    self.configuredEffort = configuredEffort
    self.modelID = modelID
    self.saidAt = saidAt
  }
}

/// How a level is given to an agent that runs, at rest at its prompt.
public enum AgentEffortChange: Sendable {
  /// A command typed into the prompt and submitted: Claude Code's `/effort high`.
  case command(String)
  /// A command that opens a panel, then the keys its screens ask for: Codex's `/model`.
  case panel(opening: String, driver: any AgentEffortPanelDriving)
}

/// Finds the keys that move a panel of the agent towards a level, one screen at a time.
public protocol AgentEffortPanelDriving: Sendable {
  func step(on screen: String) -> AgentEffortPanelStep
}

public enum AgentEffortPanelStep: Equatable, Sendable {
  /// Keys to press, after which the panel is read again.
  case press(String)
  /// The last keys: once pressed, the level is applied and the panel closes.
  case finish(String)
  /// A screen the driver does not recognise: nothing is pressed, it is read again a moment later.
  case wait
}

/// An agent whose reasoning effort can be shown and changed from the status bar (#411).
public protocol AgentEffortControlling: Sendable {
  /// The levels the model takes, lowest first. `modelID` is `nil` for the model configured.
  func effortLevels(modelID: String?) async -> [String]
  /// Whether "Default" — the agent's own setting — is one of the choices: an agent that says its
  /// level itself shows it, and has no such state.
  var offersDefaultEffort: Bool { get }
  /// What the agent says of its effort for this conversation, started at `since`.
  func effortReport(resumeIdentifier: String?, since: Date) async -> AgentEffortReport
  /// How the level is given to the agent while it runs; `nil` for its default.
  func effortChange(to level: String?) -> AgentEffortChange?
}
