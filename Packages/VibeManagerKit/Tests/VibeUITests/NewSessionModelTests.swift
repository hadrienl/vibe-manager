import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The new session sheet")
struct NewSessionModelTests {
  private func makeModel(
    providers: [StubProvider] = [StubProvider(id: "claude-code", state: .available)],
    folder: WorkingDirectoryStatus = .usable,
    repository: SpyRepository = SpyRepository()
  ) -> NewSessionModel {
    let registry = StubRegistry(providers: providers)
    return NewSessionModel(
      create: CreateSession(
        repository: repository,
        agents: registry,
        folders: StubFolders(status: folder)
      ),
      registry: registry
    )
  }

  @Test("Create stays out of reach until a name and a folder are there")
  func submissionRequiresNameAndFolder() async {
    let model = makeModel()
    await model.load(defaultWorkingDirectoryPath: nil)

    #expect(!model.canSubmit)

    model.draft.name = "Refactor the webhook"
    #expect(!model.canSubmit)

    model.draft.workingDirectoryPath = "/workspace"
    #expect(model.canSubmit)
  }

  @Test("The default agent is the first usable one, and the others stay listed")
  func defaultAgentSkipsUnusableOnes() async {
    let model = makeModel(providers: [
      StubProvider(id: "codex", state: .notFound),
      StubProvider(id: "claude-code", state: .available),
    ])

    await model.load(defaultWorkingDirectoryPath: nil)

    #expect(model.draft.providerID == "claude-code")
    #expect(model.agents.count == 2)
    #expect(model.agents.contains { !$0.isUsable })
  }

  @Test("An agent that only needs a sign-in is offered, with a warning")
  func unauthenticatedAgentIsOfferedWithAWarning() async throws {
    let model = makeModel(providers: [StubProvider(id: "gemini", state: .unauthenticated)])

    await model.load(defaultWorkingDirectoryPath: nil)

    let agent = try #require(model.agents.first)
    #expect(agent.isUsable)
    #expect(agent.warnsBeforeLaunch)
    #expect(model.draft.providerID == "gemini")
  }

  @Test("A refused submission shows every problem and creates nothing")
  func refusedSubmissionShowsProblems() async {
    let repository = SpyRepository()
    let model = makeModel(folder: .missing, repository: repository)
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refactor the webhook"
    model.draft.workingDirectoryPath = "/gone"

    let creation = await model.submit()

    #expect(creation == nil)
    #expect(model.issues.contains(.workingDirectoryNotFound))
    #expect(model.hasSubmitted)
    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("Every problem carries the way out of it")
  func everyProblemCarriesARemedy() async {
    let model = makeModel(providers: [StubProvider(id: "codex", state: .notFound)])
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.providerID = "codex"

    _ = await model.submit()

    #expect(!model.issues.isEmpty)
    #expect(model.issues.allSatisfy { !$0.remedy.isEmpty && !$0.message.isEmpty })
  }

  @Test("Fixing a field clears its problem without pressing Create again")
  func fixingAFieldClearsItsProblem() async {
    let model = makeModel()
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.workingDirectoryPath = "/workspace"
    _ = await model.submit()
    #expect(model.issues(for: .name) == [.nameMissing])

    model.draft.name = "Refactor the webhook"
    // The draft observer revalidates on the next hop of the main actor.
    await Task.yield()
    await model.revalidate()

    #expect(model.issues(for: .name).isEmpty)
  }

  @Test("An accepted submission stores the session and hands back the plan to launch")
  func acceptedSubmissionReturnsThePlan() async {
    let repository = SpyRepository()
    let model = makeModel(repository: repository)
    await model.load(defaultWorkingDirectoryPath: "/workspace")
    model.draft.name = "Refactor the webhook"

    let creation = await model.submit()

    #expect(creation?.session.name == "Refactor the webhook")
    #expect(creation?.plan.workingDirectoryPath == "/workspace")
    #expect(await repository.savedSessions.count == 1)
  }

  @Test("Changing agent drops a model the new one does not offer")
  func changingAgentResetsTheModel() async {
    let model = makeModel(providers: [
      StubProvider(
        id: "claude-code", state: .available,
        models: [
          AgentModel(id: "opus", displayName: "Opus")
        ]),
      StubProvider(id: "codex", state: .available),
    ])
    await model.load(defaultWorkingDirectoryPath: "/workspace")
    model.draft.modelID = "opus"

    model.draft.providerID = "codex"
    await Task.yield()
    await model.loadModels()

    #expect(model.draft.modelID == nil)
  }
}

private struct StubFolders: WorkingDirectoryProbe {
  let status: WorkingDirectoryStatus

  func inspect(path: String) async -> WorkingDirectoryStatus { status }
}

private actor SpyRepository: SessionRepository {
  private(set) var savedSessions: [WorkSession] = []

  func sessions() -> [WorkSession] { savedSessions }

  func session(id: SessionID) -> WorkSession? {
    savedSessions.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    savedSessions.append(session)
  }
}

private struct StubProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let catalog: [AgentModel]

  init(id: String, state: AgentAvailabilityState, models: [AgentModel] = []) {
    descriptor = AgentDescriptor(
      id: AgentProviderID(id),
      displayName: id,
      capabilities: AgentCapabilities(
        supportsModelSelection: true,
        supportsInitialPrompt: true,
        supportsResume: true
      )
    )
    self.state = state
    catalog = models
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "\(descriptor.displayName) is \(state == .available ? "ready" : "not usable").",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: state == .available ? [] : [.install(documentationURL: nil)]
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

private struct StubRegistry: AgentProviderResolving {
  let providers: [StubProvider]

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
