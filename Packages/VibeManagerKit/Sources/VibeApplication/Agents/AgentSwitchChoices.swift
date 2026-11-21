import Foundation
import VibeDomain

/// The agents and models a session can be switched to (#575), read from the registry: the list
/// the Switch Agent sheet offers, and the one the status bar's menu offers, in the same order.
///
/// Read when it is needed, and kept by no one: an agent installed or signed in since is there the
/// next time.
public struct AgentSwitchChoices: Equatable, Sendable {
  /// One registered agent, its availability, and the models its catalogue lists.
  public struct Agent: Equatable, Sendable, Identifiable {
    public let descriptor: AgentDescriptor
    public let availability: AgentAvailability
    /// Empty when the catalogue has not answered, or lists nothing — and for an agent that cannot
    /// run, whose catalogue is not read.
    public let models: [AgentModel]

    public init(descriptor: AgentDescriptor, availability: AgentAvailability, models: [AgentModel])
    {
      self.descriptor = descriptor
      self.availability = availability
      self.models = models
    }

    public var id: AgentProviderID { descriptor.id }
    public var name: String { descriptor.displayName }

    /// The catalogue's model `id` names: itself, or the newest of the family an alias names —
    /// `opus`, which Claude Code takes for its newest Opus. The catalogue lists the newest first.
    public func model(named id: String?) -> AgentModel? {
      guard let id else { return nil }
      return models.first { $0.id == id }
        ?? models.first { $0.shortName?.lowercased() == id.lowercased() }
    }
  }

  /// One entry of the menu: an agent and a model, `modelID == nil` for the agent's own default.
  public struct Choice: Equatable, Sendable, Identifiable {
    public let target: AgentTarget
    /// The model's name as its catalogue gives it, or its identifier. `nil` for the default model.
    public let modelName: String?
    /// The agent and model the session runs now.
    public let isCurrent: Bool

    public init(target: AgentTarget, modelName: String?, isCurrent: Bool) {
      self.target = target
      self.modelName = modelName
      self.isCurrent = isCurrent
    }

    public var id: AgentTarget { target }
  }

  /// Every registered agent with an availability, in registration order, the ones that cannot run
  /// included: the sheet lists them all, and says why one cannot run.
  public let agents: [Agent]

  public init(agents: [Agent]) {
    self.agents = agents
  }

  /// Reads the registry: its agents, whether each can run, and the models of each one that can.
  /// The catalogues are read side by side: one that is slow to answer — a CLI asked for its
  /// models — holds the list back no longer than itself.
  public static func read(
    from registry: any AgentProviderResolving, forceRefresh: Bool = false
  ) async -> AgentSwitchChoices {
    let descriptors = await registry.descriptors()
    let availabilities = await registry.availabilities(forceRefresh: forceRefresh)
    let usable = descriptors.filter { availabilities[$0.id]?.isUsable == true }.map(\.id)
    let catalogues = await withTaskGroup(of: (AgentProviderID, [AgentModel]).self) { group in
      for id in usable {
        group.addTask { (id, await registry.provider(id: id)?.models() ?? []) }
      }
      var catalogues: [AgentProviderID: [AgentModel]] = [:]
      for await (id, models) in group { catalogues[id] = models }
      return catalogues
    }
    let agents = descriptors.compactMap { descriptor in
      availabilities[descriptor.id].map {
        Agent(descriptor: descriptor, availability: $0, models: catalogues[descriptor.id] ?? [])
      }
    }
    return AgentSwitchChoices(agents: agents)
  }

  /// The agents a switch can go to now: the ones that can run.
  public var offered: [Agent] {
    agents.filter(\.availability.isUsable)
  }

  /// Each agent's models by identifier, to their names: how a model the session ran is named.
  /// An alias of a family — `opus` — is named after the model it stands for.
  public var modelNames: [String: [String: String]] {
    Dictionary(
      agents.map { agent in
        let aliases = agent.models.compactMap { model in
          model.shortName.map { ($0.lowercased(), model.displayName) }
        }
        let names = agent.models.map { ($0.id, $0.displayName) }
        // The identifiers first, then the newest model of each family: a real identifier is
        // never renamed by an alias.
        return (
          agent.id.rawValue,
          Dictionary(aliases.reversed() + names, uniquingKeysWith: { _, later in later })
        )
      }, uniquingKeysWith: { a, _ in a })
  }

  public func agent(_ providerID: String) -> Agent? {
    agents.first { $0.id.rawValue == providerID }
  }

  /// The models offered for `agent`, the one the session runs checked. An agent whose catalogue
  /// has not answered is offered alone, with its default model. The session's own model is
  /// offered even when the catalogue no longer lists it, as the sheet does.
  public func choices(
    for agent: Agent, current: SessionAgentConfiguration?
  ) -> [Choice] {
    let providerID = agent.id.rawValue
    // The model the session runs, an alias resolved: `opus` checks the newest Opus.
    let running =
      current?.providerID == providerID ? agent.model(named: current?.modelID)?.id : nil
    var choices = agent.models.map { model in
      Choice(
        target: AgentTarget(providerID: providerID, modelID: model.id),
        modelName: model.displayName,
        isCurrent: running == model.id)
    }
    if choices.isEmpty {
      choices.append(
        Choice(
          target: AgentTarget(providerID: providerID), modelName: nil,
          isCurrent: current?.providerID == providerID && current?.modelID == nil))
    }
    if let current, current.providerID == providerID, !choices.contains(where: \.isCurrent) {
      choices.append(
        Choice(
          target: AgentTarget(providerID: providerID, modelID: current.modelID),
          modelName: current.modelID, isCurrent: true))
    }
    return choices
  }
}
