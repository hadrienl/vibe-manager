import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The screen state of the Switch Agent sheet: which agent and model are picked, and the summary
/// the new agent would be handed.
///
/// It decides nothing that the switch itself does not decide again: the plan is built from the
/// store when the user confirms. What it holds is what the user is looking at, and what it says —
/// whether the conversation goes on, whether an agent will be stopped — is read from the same
/// facts `PlanAgentSwitch` reads.
@MainActor
@Observable
public final class AgentSwitchModel {
  public enum Handover: Equatable {
    /// Same agent, another model, and a conversation to resume: nothing is sent.
    case resumesConversation
    /// The session never ran: the new agent starts it with its own prompt.
    case firstLaunch
    /// A new conversation, handed the summary.
    case summary
    /// A new conversation, told nothing: this agent takes no prompt.
    case nothing
  }

  public let sessionID: SessionID
  public let sessionName: String
  public let current: SessionAgentConfiguration
  /// Whether the session's agent runs now, and will be stopped by the switch.
  public let stopsRunningAgent: Bool

  public private(set) var agents: [AgentOption] = []
  public private(set) var models: [AgentModel] = []
  /// The models of the agent the session runs now, to name its model the way the CLI does.
  private var currentModels: [AgentModel] = []
  public private(set) var isLoadingAgents = false
  public private(set) var providerID: String
  public private(set) var modelID: String?

  /// The text in the editor. Regenerated when the target changes, until the user edits it.
  public var summaryText: String = "" {
    didSet { isSummaryEdited = summaryText != generatedSummary?.text }
  }
  public private(set) var isSummaryEdited = false
  public private(set) var generatedSummary: SessionContextBrief?

  private let session: WorkSession
  private let registry: any AgentProviderResolving
  private let planner: PlanAgentSwitch
  private let context: @MainActor (WorkSession, [String: String]) -> SessionBriefInput

  public init(
    session: WorkSession,
    stopsRunningAgent: Bool,
    registry: any AgentProviderResolving,
    planner: PlanAgentSwitch,
    preselected: AgentTarget? = nil,
    context: @escaping @MainActor (WorkSession, [String: String]) -> SessionBriefInput
  ) {
    self.session = session
    sessionID = session.id
    sessionName = session.name
    current = session.agent ?? SessionAgentConfiguration(providerID: "")
    self.stopsRunningAgent = stopsRunningAgent
    self.registry = registry
    self.planner = planner
    self.context = context
    providerID = preselected?.providerID ?? current.providerID
    modelID = preselected?.modelID ?? current.modelID
  }

  // MARK: - What is picked

  public var target: AgentTarget {
    AgentTarget(providerID: providerID, modelID: modelID)
  }

  public var selectedAgent: AgentOption? {
    agents.first { $0.id.rawValue == providerID }
  }

  public var currentName: String {
    name(of: current.providerID)
  }

  public var targetName: String {
    name(of: providerID)
  }

  /// "Claude Code · opus", or the agent's name alone when it runs its default model.
  public var currentLabel: String {
    label(current.providerID, current.modelID, among: currentModels)
  }

  public var targetLabel: String {
    label(providerID, modelID, among: models)
  }

  public var changesSomething: Bool {
    !target.matches(session.agent)
  }

  public var handover: Handover {
    if !session.hasEverStarted { return .firstLaunch }
    let identifier = current.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    if providerID == current.providerID, identifier?.isEmpty == false,
      selectedAgent?.descriptor.capabilities.supportsResume ?? true
    {
      return .resumesConversation
    }
    if let agent = selectedAgent, !agent.descriptor.capabilities.supportsInitialPrompt {
      return .nothing
    }
    return .summary
  }

  /// The mode the sheet is showing, for the switch to confirm it is still the one it would take.
  public var expectedModeKind: AgentSwitchMode.Kind {
    switch handover {
    case .resumesConversation: return .resumeWithModel
    case .firstLaunch: return .firstLaunch
    case .summary: return isSummaryEmptied ? .freshWithoutContext : .handover
    case .nothing: return .freshWithoutContext
    }
  }

  public var summaryByteCount: Int { summaryText.utf8.count }

  public var summaryOverflow: Int {
    max(0, summaryByteCount - AgentPromptLimits.argumentByteLimit)
  }

  public var isSummaryEmptied: Bool {
    summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var canSwitch: Bool {
    guard changesSomething, selectedAgent?.isUsable == true, !isLoadingAgents else {
      return false
    }
    return handover != .summary || summaryOverflow == 0
  }

  /// The button's own words: it says that an agent will be stopped when one will.
  public var confirmTitle: String {
    stopsRunningAgent ? "Stop and Switch" : "Switch"
  }

  /// The warning shown when the switch stops a running agent.
  public var stopWarning: String? {
    guard stopsRunningAgent else { return nil }
    return """
      \(currentName) is running and will be stopped. Whatever it is doing right now will be \
      interrupted.
      """
  }

  /// What the new agent will and will not know: always said, and said for the case at hand.
  public var continuityNotice: String {
    switch handover {
    case .resumesConversation:
      let model = modelID.map { id in models.first { $0.id == id }?.displayName ?? id }
      return "The conversation continues with \(model ?? "the agent's default model")."
    case .firstLaunch:
      return """
        This session has never run: \(targetName) starts it with the prompt it was created with.
        """
    case .nothing:
      return """
        \(targetName) starts a new conversation and takes no prompt: it will not see \
        \(currentName)'s conversation, and nothing is sent to it.
        """
    case .summary:
      let whose =
        providerID == current.providerID
        ? "the previous conversation" : "\(currentName)'s conversation"
      if isSummaryEmptied {
        return """
          \(targetName) starts a new conversation. It will not see \(whose), and no summary \
          will be sent.
          """
      }
      return """
        \(targetName) starts a new conversation. It will not see \(whose) — only the summary \
        below.
        """
    }
  }

  public var accessibilityDescription: String {
    "Switch the agent of \(sessionName), currently \(currentLabel)"
      + (stopsRunningAgent ? ", running" : "")
  }

  // MARK: - Loading and picking

  public func load() async {
    await refreshAgents(forceRefresh: false)
  }

  public func refreshAgents(forceRefresh: Bool) async {
    guard !isLoadingAgents else { return }
    isLoadingAgents = true
    defer { isLoadingAgents = false }
    agents = await AgentOption.detect(in: registry, forceRefresh: forceRefresh)
    currentModels = await registry.provider(id: AgentProviderID(current.providerID))?.models() ?? []
    await loadModels()
    regenerateUnlessEdited()
  }

  /// Picks an agent and lists its models — the two belong together, as in the New Session sheet.
  /// The model the session runs is kept when the agent is the session's own.
  public func select(agent id: String) async {
    guard providerID != id else { return }
    providerID = id
    modelID = id == current.providerID ? current.modelID : nil
    await loadModels()
    regenerateUnlessEdited()
  }

  public func select(model id: String?) {
    guard modelID != id else { return }
    modelID = id
    regenerateUnlessEdited()
  }

  /// What the summary is built from has changed — a branch report arrived. The text follows,
  /// unless the user has edited it.
  public func contextChanged() {
    regenerateUnlessEdited()
  }

  /// Throws the user's edits away for the text generated for the current target.
  public func regenerateSummary() {
    let summary = planner.summary(for: context(session, agentNames), to: target)
    generatedSummary = summary
    summaryText = summary.text
  }

  private func regenerateUnlessEdited() {
    guard !isSummaryEdited else { return }
    regenerateSummary()
  }

  private func loadModels() async {
    guard let provider = await registry.provider(id: AgentProviderID(providerID)) else {
      models = []
      return
    }
    models = await provider.models()
    // A model this agent does not list is dropped, as at creation — except the one the session
    // runs, which it may still be running whatever the catalogue says today.
    if let modelID, !models.isEmpty, !models.contains(where: { $0.id == modelID }),
      !(providerID == current.providerID && modelID == current.modelID)
    {
      self.modelID = nil
    }
  }

  // MARK: - Names

  var agentNames: [String: String] {
    Dictionary(agents.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  private func name(of providerID: String) -> String {
    agents.first { $0.id.rawValue == providerID }?.name ?? providerID
  }

  private func label(_ providerID: String, _ modelID: String?, among models: [AgentModel])
    -> String
  {
    let name = name(of: providerID)
    guard let modelID else { return name }
    let model = models.first { $0.id == modelID }?.displayName ?? modelID
    return "\(name) · \(model)"
  }
}
