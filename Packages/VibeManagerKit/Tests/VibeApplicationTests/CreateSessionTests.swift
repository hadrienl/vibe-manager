import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Creating a session")
struct CreateSessionTests {
  private func draft(
    name: String = "Refactor the webhook",
    prompt: String = "Split the signature check out.",
    providerID: String? = "stub",
    modelID: String? = nil,
    path: String? = "/workspace"
  ) -> SessionDraft {
    SessionDraft(
      name: name,
      initialPrompt: prompt,
      providerID: providerID,
      modelID: modelID,
      workingDirectoryPath: path
    )
  }

  private func makeSubject(
    provider: StubProvider = StubProvider(),
    folder: WorkingDirectoryStatus = .usable,
    repository: SpyRepository = SpyRepository()
  ) -> (CreateSession, SpyRepository) {
    let create = CreateSession(
      repository: repository,
      agents: StubRegistry(providers: [provider]),
      folders: StubFolders(status: folder),
      clock: FixedClock()
    )
    return (create, repository)
  }

  @Test("A valid draft is stored once, with the plan that will be launched")
  func validDraftIsStored() async throws {
    let (create, repository) = makeSubject()

    let creation = try await create(draft())

    #expect(creation.session.name == "Refactor the webhook")
    #expect(creation.session.status == .closed)
    #expect(creation.plan?.workingDirectoryPath == "/workspace")
    #expect(await repository.savedSessions.count == 1)
  }

  @Test("A folder that disappeared is reported, and nothing is written")
  func missingFolderStopsCreation() async throws {
    let (create, repository) = makeSubject(folder: .missing)

    await #expect(throws: SessionCreationRejected.self) {
      try await create(self.draft())
    }
    #expect(
      await create.problems(with: draft(), checkingFolder: true)
        .contains(.workingDirectoryNotFound)
    )
    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("A file chosen instead of a folder says so")
  func fileInsteadOfFolder() async {
    let (create, _) = makeSubject(folder: .notADirectory)

    #expect(
      await create.problems(with: draft(), checkingFolder: true)
        .contains(.workingDirectoryNotADirectory)
    )
  }

  @Test("Validating a draft never opens the working folder")
  func validationDoesNotTouchTheDisk() async {
    // Opening a protected folder — Desktop, Documents, Downloads — is what raises a macOS consent
    // alert, and validation runs while the user types. The folder is only looked at where they
    // designated one, and at creation.
    let folders = CountingFolders()
    let create = CreateSession(
      repository: SpyRepository(),
      agents: StubRegistry(providers: [StubProvider()]),
      folders: folders,
      clock: FixedClock()
    )

    _ = await create.problems(with: draft())

    #expect(await folders.inspections.isEmpty)
  }

  @Test("Creating a session does open it, so a folder that disappeared is caught")
  func creationTouchesTheDiskOnce() async throws {
    let folders = CountingFolders()
    let create = CreateSession(
      repository: SpyRepository(),
      agents: StubRegistry(providers: [StubProvider()]),
      folders: folders,
      clock: FixedClock()
    )

    _ = try await create(draft())

    #expect(await folders.inspections == ["/workspace"])
  }

  @Test("An agent that became unusable between the form and Create blocks the launch")
  func unusableAgentStopsCreation() async {
    let (create, repository) = makeSubject(provider: StubProvider(state: .notFound))

    let issues = await create.problems(with: draft())

    #expect(issues.contains { $0.field == .agent })
    #expect(issues.contains { $0.remedy.contains("Install") })
    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("An agent that is not registered any more is named, not hidden")
  func unknownAgent() async {
    let (create, _) = makeSubject()

    let issues = await create.problems(with: draft(providerID: "retired"))

    #expect(issues.contains(.agentUnknown("retired")))
  }

  @Test("A model missing from a published catalogue is refused")
  func unknownModelIsRefused() async {
    let (create, _) = makeSubject(
      provider: StubProvider(models: [AgentModel(id: "fast", displayName: "Fast")])
    )

    #expect(await create.problems(with: draft(modelID: "deep")).contains(.modelUnknown("deep")))
  }

  @Test("An empty catalogue blocks nothing: the CLI simply never wrote one")
  func emptyCatalogueAcceptsAnyModel() async {
    let (create, _) = makeSubject()

    #expect(await create.problems(with: draft(modelID: "whatever")).isEmpty)
  }

  @Test("A prompt the agent refuses is explained on the prompt, with a way out")
  func oversizedPromptIsExplained() async throws {
    let (create, repository) = makeSubject(
      provider: StubProvider(launchFailure: .promptTooLarge(byteCount: 40_000, limit: 16_384))
    )

    let issues = await create.problems(with: draft())

    let prompt = try #require(issues.first { $0.field == .initialPrompt })
    #expect(prompt.message.contains("40000"))
    #expect(!prompt.remedy.isEmpty)
    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("An empty prompt is a choice, not a problem")
  func emptyPromptIsAccepted() async throws {
    let (create, _) = makeSubject()

    let creation = try await create(draft(prompt: "   "))

    #expect(creation.session.initialPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
  }

  @Test("A refused draft leaves the store untouched")
  func refusedDraftWritesNothing() async {
    let (create, repository) = makeSubject()

    await #expect(throws: SessionCreationRejected.self) {
      try await create(self.draft(name: " "))
    }

    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("A problem two checks agree on is stated once")
  func duplicateIssuesAreCollapsed() async {
    // The draft rejects a relative folder, and so does the agent when asked for a launch plan:
    // the sheet must not list the same sentence twice, nor count one problem as two.
    let (create, _) = makeSubject(
      provider: StubProvider(launchFailure: .invalidWorkingDirectory)
    )

    let issues = await create.problems(with: draft(path: "workspace"))

    #expect(issues.filter { $0 == .workingDirectoryNotAbsolute }.count == 1)
    #expect(Set(issues.map(\.id)).count == issues.count)
  }

  @Test("A store that refuses the write surfaces its error rather than a fake session")
  func storeFailureIsPropagated() async {
    let repository = SpyRepository(failsOnSave: true)
    let (create, _) = makeSubject(repository: repository)

    await #expect(throws: (any Error).self) {
      try await create(self.draft())
    }
  }
}

private struct FixedClock: SessionClock {
  func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor CountingFolders: WorkingDirectoryProbe {
  private(set) var inspections: [String] = []

  func inspect(path: String) async -> WorkingDirectoryStatus {
    inspections.append(path)
    return .usable
  }
}

private struct StubFolders: WorkingDirectoryProbe {
  let status: WorkingDirectoryStatus

  func inspect(path: String) async -> WorkingDirectoryStatus { status }
}

private actor SpyRepository: SessionRepository {
  private(set) var savedSessions: [WorkSession] = []
  private let failsOnSave: Bool

  init(failsOnSave: Bool = false) {
    self.failsOnSave = failsOnSave
  }

  func sessions() -> [WorkSession] { savedSessions }

  func session(id: SessionID) -> WorkSession? {
    savedSessions.first { $0.id == id }
  }

  func save(_ session: WorkSession) throws {
    if failsOnSave { throw StoreFailure() }
    savedSessions.append(session)
  }
}

private struct StoreFailure: Error {}

private struct StubProvider: AgentProvider {
  let descriptor = AgentDescriptor(
    id: AgentProviderID("stub"),
    displayName: "Stub Agent",
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    )
  )
  var state: AgentAvailabilityState = .available
  var models: [AgentModel] = []
  var launchFailure: AgentLaunchError?

  init(
    state: AgentAvailabilityState = .available,
    models: [AgentModel] = [],
    launchFailure: AgentLaunchError? = nil
  ) {
    self.state = state
    self.models = models
    self.launchFailure = launchFailure
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "Stub Agent is \(state == .available ? "ready" : "unusable").",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: state == .available ? [] : [.install(documentationURL: nil)]
      )
    )
  }

  func models() async -> [AgentModel] { models }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    if let launchFailure { throw launchFailure }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

private struct StubRegistry: AgentProviderResolving {
  var providers: [StubProvider]

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
