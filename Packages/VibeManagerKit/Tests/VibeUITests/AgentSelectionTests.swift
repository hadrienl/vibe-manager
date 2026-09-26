import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Reacting to a change of agent")
struct AgentSelectionTests {
  private func makeModel() -> NewSessionModel {
    let registry = TwoAgentRegistry()
    return NewSessionModel(
      create: CreateSession(
        repository: NullRepository(),
        agents: registry,
        folders: AlwaysUsableFolders()
      ),
      registry: registry
    )
  }

  @Test("The models offered are those of the selected agent")
  func modelsFollowTheSelectedAgent() async {
    let model = makeModel()
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
    #expect(model.draft.providerID == "claude-code")
    #expect(model.models.map(\.id) == ["claude-opus-5"])

    await model.select(agent: "codex")

    #expect(model.models.map(\.id) == ["gpt-6-astra"])
  }

  @Test("Changing agent drops the model the previous one offered")
  func modelIsClearedWithTheAgent() async {
    let model = makeModel()
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
    model.draft.modelID = "claude-opus-5"

    await model.select(agent: "codex")

    #expect(model.draft.modelID == nil)
  }

  @Test("Selecting the agent already selected changes nothing")
  func reselectingIsANoOp() async {
    let model = makeModel()
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
    model.draft.modelID = "claude-opus-5"

    await model.select(agent: "claude-code")

    #expect(model.draft.modelID == "claude-opus-5")
    #expect(model.models.map(\.id) == ["claude-opus-5"])
  }
}

private struct AlwaysUsableFolders: WorkingDirectoryProbe {
  func inspect(path: String) async -> WorkingDirectoryStatus { .usable }
}

private actor NullRepository: SessionRepository {
  func sessions() -> [WorkSession] { [] }
  func session(id: SessionID) -> WorkSession? { nil }
  func save(_ session: WorkSession) {}
}

private struct CatalogProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let catalog: [AgentModel]

  init(id: String, models: [AgentModel]) {
    descriptor = AgentDescriptor(
      id: AgentProviderID(id),
      displayName: id,
      capabilities: AgentCapabilities(supportsModelSelection: true)
    )
    catalog = models
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: .available,
        summary: "ready",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: []
      )
    )
  }

  func models() async -> [AgentModel] { catalog }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: .none
    )
  }
}

private struct TwoAgentRegistry: AgentProviderResolving {
  private let providers = [
    CatalogProvider(
      id: "claude-code",
      models: [AgentModel(id: "claude-opus-5", displayName: "Opus 5")]
    ),
    CatalogProvider(
      id: "codex",
      models: [AgentModel(id: "gpt-6-astra", displayName: "GPT-6-Astra")]
    ),
  ]

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
