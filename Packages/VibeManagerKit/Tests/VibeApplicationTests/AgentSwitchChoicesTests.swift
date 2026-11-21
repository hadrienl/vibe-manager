import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// What the status bar's menu and the Switch Agent sheet offer to switch to (#575).
@Suite("The agents and models a session can be switched to")
struct AgentSwitchChoicesTests {
  private static let claude = ChoicesProvider(
    id: "claude-code", name: "Claude Code",
    models: [
      AgentModel(id: "opus", displayName: "Opus 5.5"),
      AgentModel(id: "sonnet", displayName: "Sonnet 5.5"),
    ])
  private static let codex = ChoicesProvider(
    id: "codex", name: "Codex", models: [AgentModel(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol")])
  private static let gemini = ChoicesProvider(
    id: "gemini", name: "Gemini", models: [], isUsable: false)
  private static let antigravity = ChoicesProvider(
    id: "antigravity", name: "Antigravity", models: [])

  private func read(_ providers: [ChoicesProvider]) async -> AgentSwitchChoices {
    await AgentSwitchChoices.read(from: ChoicesRegistry(providers: providers))
  }

  @Test("The agents come in the registry's order, the sheet's, with their catalogues")
  func registryOrder() async {
    let choices = await read([Self.codex, Self.gemini, Self.claude])
    #expect(choices.agents.map(\.id.rawValue) == ["codex", "gemini", "claude-code"])
    #expect(choices.agent("claude-code")?.models.map(\.id) == ["opus", "sonnet"])
  }

  @Test("An agent that cannot run is not offered, and stays in the sheet's list")
  func unusableLeftOut() async {
    let choices = await read([Self.claude, Self.gemini, Self.codex])
    #expect(choices.offered.map(\.id.rawValue) == ["claude-code", "codex"])
    #expect(choices.agents.contains { $0.id.rawValue == "gemini" })
  }

  @Test("An agent whose catalogue lists nothing is offered alone, with its default model")
  func emptyCatalogue() async throws {
    let choices = await read([Self.antigravity])
    let agent = try #require(choices.agent("antigravity"))
    let offered = choices.choices(for: agent, current: nil)
    #expect(offered.map(\.target) == [AgentTarget(providerID: "antigravity")])
    #expect(offered.first?.modelName == nil)
  }

  @Test("The model the session runs is checked, and only it")
  func currentChecked() async throws {
    let choices = await read([Self.claude, Self.codex])
    let current = SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet")
    let claude = try #require(choices.agent("claude-code"))
    let codex = try #require(choices.agent("codex"))
    #expect(
      choices.choices(for: claude, current: current).map(\.isCurrent) == [false, true])
    #expect(choices.choices(for: codex, current: current).allSatisfy { !$0.isCurrent })
  }

  @Test("A model the catalogue no longer lists is still offered, checked, when the session runs it")
  func currentOutsideCatalogue() async throws {
    let choices = await read([Self.claude])
    let claude = try #require(choices.agent("claude-code"))
    let retired = choices.choices(
      for: claude, current: SessionAgentConfiguration(providerID: "claude-code", modelID: "haiku"))
    #expect(retired.map(\.target.modelID) == ["opus", "sonnet", "haiku"])
    #expect(retired.last?.isCurrent == true)
    let standard = choices.choices(
      for: claude, current: SessionAgentConfiguration(providerID: "claude-code"))
    #expect(standard.last?.target == AgentTarget(providerID: "claude-code"))
    #expect(standard.last?.isCurrent == true)
  }

  @Test("An alias of a family names, and checks, the newest model of it")
  func aliasResolved() async throws {
    let claude = ChoicesProvider(
      id: "claude-code", name: "Claude Code",
      models: [
        AgentModel(id: "claude-opus-5-5", displayName: "Opus 5.5", shortName: "Opus"),
        AgentModel(id: "claude-sonnet-5-5", displayName: "Sonnet 5.5", shortName: "Sonnet"),
        AgentModel(id: "claude-opus-5", displayName: "Opus 5", shortName: "Opus"),
      ])
    let choices = await read([claude])
    let agent = try #require(choices.agent("claude-code"))

    #expect(choices.modelNames["claude-code"]?["opus"] == "Opus 5.5")
    #expect(choices.modelNames["claude-code"]?["claude-opus-5"] == "Opus 5")
    let offered = choices.choices(
      for: agent, current: SessionAgentConfiguration(providerID: "claude-code", modelID: "opus"))
    #expect(offered.map(\.modelName) == ["Opus 5.5", "Sonnet 5.5", "Opus 5"])
    #expect(offered.map(\.isCurrent) == [true, false, false])
  }
}

private struct ChoicesProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let catalogue: [AgentModel]
  let isUsable: Bool

  init(id: String, name: String, models: [AgentModel], isUsable: Bool = true) {
    descriptor = AgentDescriptor(id: AgentProviderID(id), displayName: name)
    catalogue = models
    self.isUsable = isUsable
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    let state: AgentAvailabilityState = isUsable ? .available : .notFound
    return AgentAvailability(
      state: state, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: state,
        summary: "", probedAt: Date(timeIntervalSince1970: 0), remediations: []))
  }

  func models() async -> [AgentModel] { catalogue }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    fatalError("not used")
  }
}

private struct ChoicesRegistry: AgentProviderResolving {
  let providers: [ChoicesProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}
