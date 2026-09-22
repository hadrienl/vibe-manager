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
    repository: SpyRepository = SpyRepository(),
    folders: (any WorkingDirectoryProbe)? = nil,
    revalidationDelay: Duration = .milliseconds(250),
    fullDiskAccess: FullDiskAccessStatus? = .notGranted
  ) -> NewSessionModel {
    let registry = StubRegistry(providers: providers)
    return NewSessionModel(
      create: CreateSession(
        repository: repository,
        agents: registry,
        folders: folders ?? StubFolders(status: folder)
      ),
      registry: registry,
      revalidationDelay: revalidationDelay,
      fullDiskAccess: fullDiskAccess
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
    // What the sheet does on every field change, once the user has asked for the session.
    await model.revalidateIfSubmitted()

    #expect(model.issues(for: .name).isEmpty)
  }

  @Test("Before the first Create, editing a field reports nothing")
  func noNaggingBeforeTheFirstSubmission() async {
    let model = makeModel()
    await model.load(defaultWorkingDirectoryPath: nil)

    model.draft.name = "R"
    await model.revalidateIfSubmitted()

    #expect(model.issues.isEmpty)
  }

  @Test("A burst of keystrokes is checked once, when the typing stops")
  func revalidationIsDebounced() async throws {
    let plans = PlanCounter()
    let model = makeModel(
      providers: [StubProvider(id: "claude-code", state: .available, plans: plans)],
      revalidationDelay: .milliseconds(40)
    )
    await model.load(defaultWorkingDirectoryPath: "/workspace")
    _ = await model.submit()
    let beforeTyping = await plans.count

    for character in "Refactor the webhook" {
      model.draft.name.append(character)
      model.draftChanged()
    }
    try await Task.sleep(for: .milliseconds(300))

    #expect(await plans.count == beforeTyping + 1)
    #expect(model.issues.isEmpty)
  }

  @Test("Typing a path never opens it: that is what raises a system alert")
  func typingAPathDoesNotReadTheDisk() async throws {
    let folders = CountingFolders()
    let model = makeModel(folders: folders, revalidationDelay: .milliseconds(40))
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refactor the webhook"
    model.draft.workingDirectoryPath = "/workspace"
    _ = await model.submit()
    await folders.reset()

    for character in "/Documents/notes" {
      model.draft.workingDirectoryPath?.append(character)
      model.draftChanged()
    }
    try await Task.sleep(for: .milliseconds(300))

    #expect(await folders.count == 0)
  }

  @Test("The folder designated in the open panel is the one that gets checked")
  func choosingAFolderChecksIt() async {
    let folders = CountingFolders()
    let model = makeModel(folders: folders)
    await model.load(defaultWorkingDirectoryPath: nil)

    await model.folderChosen("/workspace")

    #expect(model.draft.workingDirectoryPath == "/workspace")
    #expect(await folders.count == 1)
  }

  @Test("A folder that cannot be read is said at once, and nothing else is")
  func chosenFolderReportsItsOwnProblem() async {
    let model = makeModel(folder: .missing)
    await model.load(defaultWorkingDirectoryPath: nil)

    await model.folderChosen("/gone")

    #expect(model.issues == [.workingDirectoryNotFound])
    // The name has not been typed yet, and the sheet does not turn red over it.
    #expect(model.issues(for: .name).isEmpty)
  }

  @Test("Editing the path afterwards drops a verdict that no longer judges it")
  func editingThePathClearsTheChosenFolderVerdict() async {
    let model = makeModel(folder: .missing)
    await model.load(defaultWorkingDirectoryPath: nil)
    await model.folderChosen("/gone")
    #expect(!model.issues.isEmpty)

    model.draft.workingDirectoryPath = "/gone/elsewhere"
    model.draftChanged()

    #expect(model.issues.isEmpty)
  }

  @Test("A folder macOS guards is remarked upon, and never blocks creation")
  func protectedFolderIsARemark() async {
    let model = makeModel()
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.name = "Refactor the webhook"
    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Documents/notes"

    #expect(model.protectedLocationNotice != nil)
    #expect(model.canSubmit)

    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Code/vibe-manager"
    #expect(model.protectedLocationNotice == nil)
  }

  @Test("With the access granted, there is nothing left to remark upon")
  func grantedAccessSaysNothing() async {
    let model = makeModel(fullDiskAccess: .granted)
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Documents/notes"

    #expect(model.protectedLocationNotice == nil)
  }

  @Test("An access not probed yet says nothing rather than guessing")
  func unknownAccessSaysNothing() async {
    // Warning someone who granted the access long ago would be worse than staying quiet: the
    // sheet only remarks on what the application positively knows.
    let model = makeModel(fullDiskAccess: nil)
    await model.load(defaultWorkingDirectoryPath: nil)
    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Documents/notes"

    #expect(model.protectedLocationNotice == nil)
  }

  @Test("A folder that disappeared stays reported while the next field is fixed")
  func folderVerdictSurvivesTheNextEdit() async throws {
    // The folder was opened by Create, so re-checking it raises nothing new. Skipping the check
    // instead made the problem vanish as soon as the name was edited, and come back at the next
    // Create — a form that contradicts itself.
    let model = makeModel(folder: .missing, revalidationDelay: .milliseconds(10))
    await model.load(defaultWorkingDirectoryPath: "/gone")
    _ = await model.submit()
    #expect(model.issues.contains(.workingDirectoryNotFound))

    model.draft.name = "Refactor the webhook"
    model.draftChanged()
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.issues.contains(.workingDirectoryNotFound))
    #expect(model.issues(for: .name).isEmpty)
  }

  @Test("A folder chosen while the form is already red does not republish a stale verdict")
  func chosenFolderDoesNotRestoreAStaleVerdict() async throws {
    // A folder on a network volume takes long enough to check for a name to be typed under it.
    // The answer that comes back describes the older draft, so only the part of it that was
    // asked about — the folder — is kept.
    let folders = GatedFolders()
    let model = makeModel(folders: folders, revalidationDelay: .milliseconds(10))
    await model.load(defaultWorkingDirectoryPath: nil)
    _ = await model.submit()
    #expect(model.issues.contains(.nameMissing))

    let choosing = Task { await model.folderChosen("/workspace") }
    await Task.yield()
    model.draft.name = "Refactor the webhook"
    model.draftChanged()
    await folders.open()
    await choosing.value
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.issues.isEmpty)
  }

  @Test("A verdict on a draft the user has already moved past is dropped")
  func staleVerdictIsNotShown() async {
    // The checks cross actors, so they can finish in an order the typing never had. A verdict
    // that arrives late must not contradict the form the user is looking at.
    let folders = GatedFolders(open: true)
    let model = makeModel(folders: folders)
    await model.load(defaultWorkingDirectoryPath: nil)
    // Designated through the panel first, so the check that follows really reads the folder — and
    // really does wait at the gate, rather than counting on the scheduler to be slow enough.
    await model.folderChosen("/workspace")
    await folders.close()

    let checking = Task { await model.revalidate() }
    await folders.waitForCheck()
    model.draft.name = "Refactor the webhook"
    await folders.open()
    await checking.value

    #expect(model.issues.isEmpty)
  }

  @Test("A pending check never overwrites the verdict of a submission")
  func submissionSurvivesAPendingCheck() async throws {
    let model = makeModel(revalidationDelay: .milliseconds(40))
    await model.load(defaultWorkingDirectoryPath: "/workspace")
    _ = await model.submit()
    #expect(model.issues == [.nameMissing])

    // A keystroke, then Create pressed before the debounce fires.
    model.draft.name = "Refactor the webhook"
    model.draftChanged()
    let creation = await model.submit()
    try await Task.sleep(for: .milliseconds(200))

    #expect(creation != nil)
    #expect(model.issues.isEmpty)
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

    await model.select(agent: "codex")

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

/// Counts the checks that reach the agent, which is what a revalidation costs now that the
/// working folder is left alone until the user designates one.
private actor PlanCounter {
  private(set) var count = 0

  func record() { count += 1 }
}

private struct StubProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let catalog: [AgentModel]
  let plans: PlanCounter?

  init(
    id: String,
    state: AgentAvailabilityState,
    models: [AgentModel] = [],
    plans: PlanCounter? = nil
  ) {
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
    self.plans = plans
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
    await plans?.record()
    return AgentLaunchPlan(
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

/// Counts how many times a draft was actually checked against the disk.
private actor CountingFolders: WorkingDirectoryProbe {
  private(set) var count = 0

  func reset() { count = 0 }

  func inspect(path: String) -> WorkingDirectoryStatus {
    count += 1
    return .usable
  }
}

/// A probe that holds a check open, so the draft can change while it is in flight.
private actor GatedFolders: WorkingDirectoryProbe {
  private var isOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var isChecking = false
  private var arrivals: [CheckedContinuation<Void, Never>] = []

  init(open: Bool = false) {
    isOpen = open
  }

  func open() {
    isOpen = true
    let waiters = self.waiters
    self.waiters = []
    waiters.forEach { $0.resume() }
  }

  func close() {
    isOpen = false
  }

  /// Returns once a check is actually waiting at the gate, so a test never has to guess whether
  /// the scheduler has started it yet.
  func waitForCheck() async {
    guard !isChecking else { return }
    await withCheckedContinuation { arrivals.append($0) }
  }

  func inspect(path: String) async -> WorkingDirectoryStatus {
    isChecking = true
    let arrivals = self.arrivals
    self.arrivals = []
    arrivals.forEach { $0.resume() }
    while !isOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    isChecking = false
    return .usable
  }
}
