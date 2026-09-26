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
    await model.load()

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

    await model.load()

    #expect(model.draft.providerID == "claude-code")
    #expect(model.agents.count == 2)
    #expect(model.agents.contains { !$0.isUsable })
  }

  @Test("An agent that only needs a sign-in is offered, with a warning")
  func unauthenticatedAgentIsOfferedWithAWarning() async throws {
    let model = makeModel(providers: [StubProvider(id: "gemini", state: .unauthenticated)])

    await model.load()

    let agent = try #require(model.agents.first)
    #expect(agent.isUsable)
    #expect(agent.warnsBeforeLaunch)
    #expect(model.draft.providerID == "gemini")
  }

  @Test("A refused submission shows every problem and creates nothing")
  func refusedSubmissionShowsProblems() async {
    let repository = SpyRepository()
    let model = makeModel(folder: .missing, repository: repository)
    await model.load()
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
    await model.load()
    model.draft.providerID = "codex"

    _ = await model.submit()

    #expect(!model.issues.isEmpty)
    #expect(model.issues.allSatisfy { !$0.remedy.isEmpty && !$0.message.isEmpty })
  }

  @Test("Fixing a field clears its problem without pressing Create again")
  func fixingAFieldClearsItsProblem() async {
    let model = makeModel()
    await model.load()
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
    await model.load()

    model.draft.name = "R"
    await model.revalidateIfSubmitted()

    #expect(model.issues.isEmpty)
  }

  @Test("A burst of keystrokes is checked once, when the typing stops", .timeLimit(.minutes(1)))
  func revalidationIsDebounced() async throws {
    let plans = PlanCounter()
    let model = makeModel(
      providers: [StubProvider(id: "claude-code", state: .available, plans: plans)],
      revalidationDelay: .milliseconds(40)
    )
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
    _ = await model.submit()
    let beforeTyping = await plans.count

    for character in "Refactor the webhook" {
      model.draft.name.append(character)
      model.draftChanged()
    }
    await waitUntil { model.issues.isEmpty }
    // Long enough for any other check the burst might have started to land as well.
    try await Task.sleep(for: .milliseconds(100))

    #expect(await plans.count == beforeTyping + 1)
    #expect(model.issues.isEmpty)
  }

  @Test("Typing a path never opens it: that is what raises a system alert")
  func typingAPathDoesNotReadTheDisk() async throws {
    let folders = CountingFolders()
    let model = makeModel(folders: folders, revalidationDelay: .milliseconds(40))
    await model.load()
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
    await model.load()

    await model.folderChosen("/workspace")

    #expect(model.draft.workingDirectoryPath == "/workspace")
    #expect(await folders.count == 1)
  }

  @Test("A folder that cannot be read is said at once, and nothing else is")
  func chosenFolderReportsItsOwnProblem() async {
    let model = makeModel(folder: .missing)
    await model.load()

    await model.folderChosen("/gone")

    #expect(model.issues == [.workingDirectoryNotFound])
    // The name has not been typed yet, and the sheet does not turn red over it.
    #expect(model.issues(for: .name).isEmpty)
  }

  @Test("Editing the path afterwards drops a verdict that no longer judges it")
  func editingThePathClearsTheChosenFolderVerdict() async {
    let model = makeModel(folder: .missing)
    await model.load()
    await model.folderChosen("/gone")
    #expect(!model.issues.isEmpty)

    model.draft.workingDirectoryPath = "/gone/elsewhere"
    model.draftChanged()

    #expect(model.issues.isEmpty)
  }

  @Test("A folder macOS guards is remarked upon, and never blocks creation")
  func protectedFolderIsARemark() async {
    let model = makeModel()
    await model.load()
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
    await model.load()
    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Documents/notes"

    #expect(model.protectedLocationNotice == nil)
  }

  @Test("An access not probed yet says nothing rather than guessing")
  func unknownAccessSaysNothing() async {
    // Warning someone who granted the access long ago would be worse than staying quiet: the
    // sheet only remarks on what the application positively knows.
    let model = makeModel(fullDiskAccess: nil)
    await model.load()
    model.draft.workingDirectoryPath = NSHomeDirectory() + "/Documents/notes"

    #expect(model.protectedLocationNotice == nil)
  }

  @Test(
    "A folder that disappeared stays reported while the next field is fixed",
    .timeLimit(.minutes(1))
  )
  func folderVerdictSurvivesTheNextEdit() async throws {
    // The folder was opened by Create, so re-checking it raises nothing new. Skipping the check
    // instead made the problem vanish as soon as the name was edited, and come back at the next
    // Create — a form that contradicts itself.
    let model = makeModel(folder: .missing, revalidationDelay: .milliseconds(10))
    model.draft.workingDirectoryPath = "/gone"
    await model.load()
    _ = await model.submit()
    #expect(model.issues.contains(.workingDirectoryNotFound))

    model.draft.name = "Refactor the webhook"
    model.draftChanged()
    await waitUntil { model.issues(for: .name).isEmpty }

    #expect(model.issues.contains(.workingDirectoryNotFound))
    #expect(model.issues(for: .name).isEmpty)
  }

  @Test(
    "A folder chosen while the form is already red does not republish a stale verdict",
    .timeLimit(.minutes(1))
  )
  func chosenFolderDoesNotRestoreAStaleVerdict() async throws {
    // A folder on a network volume takes long enough to check for a name to be typed under it.
    // The answer that comes back describes the older draft, so only the part of it that was
    // asked about — the folder — is kept.
    let folders = GatedFolders()
    let model = makeModel(folders: folders, revalidationDelay: .milliseconds(10))
    await model.load()
    _ = await model.submit()
    #expect(model.issues.contains(.nameMissing))

    let choosing = Task { await model.folderChosen("/workspace") }
    await Task.yield()
    model.draft.name = "Refactor the webhook"
    model.draftChanged()
    await folders.open()
    await choosing.value
    await waitUntil { model.issues.isEmpty }

    #expect(model.issues.isEmpty)
  }

  @Test("A verdict on a draft the user has already moved past is dropped")
  func staleVerdictIsNotShown() async {
    // The checks cross actors, so they can finish in an order the typing never had. A verdict
    // that arrives late must not contradict the form the user is looking at.
    let folders = GatedFolders(open: true)
    let model = makeModel(folders: folders)
    await model.load()
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
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
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
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
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
    model.draft.workingDirectoryPath = "/workspace"
    await model.load()
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
/// Waits for the debounced check to land, however long a busy runner takes to get there.
///
/// No deadline of its own: a fixed wait of 200 ms ran out on a CI runner where these tests took
/// seven seconds. The time limit of each test stops a check that never comes.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
  while !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

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

private let templateReview = PromptTemplate(
  name: "Review", sessionNamePattern: "Review {{url}}", body: "Review {{url}}.\n\n{{focus?}}")
private let templateFeedback = PromptTemplate(
  name: "Feedback", sessionNamePattern: "Feedback {{url}}", body: "Address comments on {{url}}.")

@MainActor
@Suite("Filling a template in the new session sheet")
struct NewSessionTemplateTests {
  private func makeModel(templates: [PromptTemplate] = [templateReview, templateFeedback])
    -> NewSessionModel
  {
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    let model = NewSessionModel(
      create: CreateSession(
        repository: SpyRepository(), agents: registry, folders: StubFolders(status: .usable)),
      registry: registry,
      templates: templates
    )
    model.draft.workingDirectoryPath = "/workspace"
    return model
  }

  @Test("Create stays out of reach while a required field is empty")
  func requiredFieldBlocksSubmission() {
    let model = makeModel()
    model.selectTemplate(templateReview.id)
    #expect(model.draft.name == "Review")
    #expect(!model.canSubmit)

    model.setValue("https://x/1", for: "url")
    #expect(model.canSubmit)
    #expect(model.draft.name == "Review https://x/1")
  }

  @Test("The name follows the template until the user types their own")
  func nameStopsFollowingOnceTyped() {
    let model = makeModel()
    model.selectTemplate(templateReview.id)
    model.draft.name = "My own name"
    model.setValue("https://x/1", for: "url")
    #expect(model.draft.name == "My own name")
  }

  @Test("Changing template keeps the values of fields sharing a name")
  func switchingKeepsSharedValues() {
    let model = makeModel()
    model.selectTemplate(templateReview.id)
    model.setValue("https://x/1", for: "url")
    model.setValue("the migration", for: "focus")
    model.selectTemplate(templateFeedback.id)
    #expect(model.value(for: "url") == "https://x/1")
    #expect(model.draft.templateFill?.values["focus"] == nil)
    #expect(model.draft.name == "Feedback https://x/1")
  }

  @Test("Edit as Text turns the rendering into the free prompt, and drops the template")
  func editAsText() {
    let model = makeModel()
    model.selectTemplate(templateReview.id)
    model.editAsText()
    #expect(model.draft.templateFill == nil)
    #expect(model.draft.initialPrompt == "Review {{url}}.")
    #expect(model.draft.session().template == nil)
  }

  @Test("A template saved elsewhere is said, and only swapped in on Reload")
  func staleTemplateReloads() {
    let model = makeModel()
    model.selectTemplate(templateReview.id)
    model.setValue("https://x/1", for: "url")
    var changed = templateReview
    changed.body = "Look at {{url}} closely."
    changed.revision = 2

    model.templatesChanged([changed, templateFeedback])
    #expect(model.isTemplateStale)
    #expect(model.renderedPrompt?.prompt == "Review https://x/1.")

    model.reloadTemplate()
    #expect(!model.isTemplateStale)
    #expect(model.renderedPrompt?.prompt == "Look at https://x/1 closely.")
  }

  @Test("A template's folder is proposed while the field is free, and follows the template")
  func folderPresetFollowsTemplate() {
    var api = templateReview
    api.workingDirectoryPath = "~/Projects/api"
    let model = makeModel(templates: [api, templateFeedback])
    model.draft.workingDirectoryPath = nil

    model.selectTemplate(api.id)
    #expect(model.draft.workingDirectoryPath == "~/Projects/api")
    #expect(model.folderComesFromTemplate)

    // A template without a folder gives back the one that was there before.
    model.selectTemplate(templateFeedback.id)
    #expect(model.draft.workingDirectoryPath == nil)
    #expect(!model.folderComesFromTemplate)
  }

  @Test("A template's symbol and colour follow it, and never replace the user's")
  func appearancePreset() {
    var api = templateReview
    let given = SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5")
    api.appearance = given
    let model = makeModel(templates: [api, templateFeedback])

    model.selectTemplate(api.id)
    #expect(model.draft.appearance == given)
    #expect(model.appearanceComesFromTemplate)
    model.selectTemplate(templateFeedback.id)
    #expect(model.draft.appearance == nil)

    let mine = SessionAppearance(symbolName: "flask", colorHex: "#B42318")
    model.draft.appearance = mine
    model.selectTemplate(api.id)
    #expect(model.draft.appearance == mine)
  }

  @Test("A folder the user chose is never replaced by a template's")
  func userFolderWins() {
    var api = templateReview
    api.workingDirectoryPath = "~/Projects/api"
    let model = makeModel(templates: [api, templateFeedback])
    model.draft.workingDirectoryPath = "/workspace/mine"

    model.selectTemplate(api.id)
    #expect(model.draft.workingDirectoryPath == "/workspace/mine")

    // Chosen after the template proposed one, it stays through a change of template too.
    model.draft.workingDirectoryPath = nil
    model.selectTemplate(templateFeedback.id)
    model.selectTemplate(api.id)
    model.draft.workingDirectoryPath = "/workspace/other"
    model.selectTemplate(templateFeedback.id)
    #expect(model.draft.workingDirectoryPath == "/workspace/other")
  }
}

/// Finds, for each folder, the icon it was given.
private struct StubIcons: ProjectIconFinding {
  let icons: [String: ProjectIcon]
  var delay: Duration = .zero

  func icon(inFolder path: String) async -> ProjectIcon? {
    try? await Task.sleep(for: delay)
    return icons[path]
  }
}

private func projectIcon(_ digit: Character) -> ProjectIcon {
  // The digest is only a name here: the tests never read the bytes as an image.
  guard let id = SessionIconID(sha256: String(repeating: digit, count: 64)) else {
    preconditionFailure("Not a digest")
  }
  return ProjectIcon(id: id, pngData: Data([UInt8(digit.asciiValue ?? 0)]))
}

@MainActor
@Suite("The project icon in the new session sheet")
struct NewSessionProjectIconTests {
  private func makeModel(
    icons: [String: ProjectIcon],
    delay: Duration = .zero,
    repository: SpyRepository = SpyRepository(),
    store: InMemorySessionIconStore = InMemorySessionIconStore()
  ) -> NewSessionModel {
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    return NewSessionModel(
      create: CreateSession(
        repository: repository, agents: registry, folders: StubFolders(status: .usable),
        icons: store),
      registry: registry,
      projectIcons: StubIcons(icons: icons, delay: delay))
  }

  @Test("A folder's icon is the default, in place of what the name gives")
  func iconIsTheDefault() async throws {
    let icon = projectIcon("a")
    let repository = SpyRepository()
    let store = InMemorySessionIconStore()
    let model = makeModel(icons: ["/work/api": icon], repository: repository, store: store)
    await model.load()
    model.draft.name = "Refactor"

    await model.folderChosen("/work/api")
    await waitUntil { model.draft.projectIcon != nil }

    #expect(model.usesProjectIcon)
    #expect(model.draft.effectiveAppearance.iconID == icon.id)
    _ = try #require(await model.submit())
    #expect(await repository.savedSessions.first?.appearance.iconID == icon.id)
    #expect(await store.pngData(for: icon.id) == icon.pngData)
  }

  @Test("A symbol picked by the user is never replaced, not even by another folder's icon")
  func explicitChoiceIsKept() async {
    let model = makeModel(icons: ["/work/api": projectIcon("a"), "/work/web": projectIcon("b")])
    await model.load()
    model.draft.name = "Refactor"
    await model.folderChosen("/work/api")
    await waitUntil { model.draft.projectIcon != nil }

    let chosen = SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5")
    model.draft.appearance = chosen
    await model.folderChosen("/work/web")
    await waitUntil { model.draft.projectIcon != nil }

    #expect(model.draft.effectiveAppearance == chosen)
    #expect(!model.usesProjectIcon)
    model.useProjectIcon()
    #expect(model.draft.effectiveAppearance.iconID == projectIcon("b").id)
  }

  @Test("Without an icon, the name decides, as it always has")
  func noIcon() async {
    let model = makeModel(icons: [:])
    await model.load()
    model.draft.name = "Refactor"

    await model.folderChosen("/work/api")

    #expect(model.draft.projectIcon == nil)
    #expect(
      model.draft.effectiveAppearance == SessionAppearanceCatalog.derived(forName: "Refactor"))
  }

  @Test("An answer about a folder the field no longer names is dropped")
  func staleAnswerIsDropped() async throws {
    let model = makeModel(icons: ["/work/api": projectIcon("a")], delay: .milliseconds(100))
    await model.load()

    await model.folderChosen("/work/api")
    model.draft.workingDirectoryPath = "/work/other"
    model.draftChanged()
    try await Task.sleep(for: .milliseconds(250))

    #expect(model.draft.projectIcon == nil)
  }

  @Test("An icon that cannot be kept leaves the session created, wearing its name")
  func failedWriteStillCreates() async throws {
    struct Full: Error {}
    let repository = SpyRepository()
    let model = makeModel(
      icons: ["/work/api": projectIcon("a")], repository: repository,
      store: InMemorySessionIconStore(failure: Full()))
    await model.load()
    model.draft.name = "Refactor"
    await model.folderChosen("/work/api")
    await waitUntil { model.draft.projectIcon != nil }

    _ = try #require(await model.submit())

    let saved = await repository.savedSessions.first?.appearance
    #expect(saved == SessionAppearanceCatalog.derived(forName: "Refactor"))
  }

  @Test("Editing the folder and coming back to it finds its icon again")
  func comingBackToTheFolder() async throws {
    let repository = SpyRepository()
    let model = makeModel(icons: ["/work/api": projectIcon("a")], repository: repository)
    await model.load()
    model.draft.name = "Refactor"
    await model.folderChosen("/work/api")
    await waitUntil { model.draft.projectIcon != nil }

    model.draft.workingDirectoryPath = "/work/ap"
    model.draftChanged()
    model.draft.workingDirectoryPath = "/work/api"
    model.draftChanged()
    _ = try #require(await model.submit())

    #expect(await repository.savedSessions.first?.appearance.iconID == projectIcon("a").id)
  }

  @Test("A typed folder gets its icon at creation")
  func typedFolderAtCreation() async throws {
    let repository = SpyRepository()
    let model = makeModel(icons: ["/work/api": projectIcon("a")], repository: repository)
    await model.load()
    model.draft.name = "Refactor"
    model.draft.workingDirectoryPath = "/work/api"

    _ = try #require(await model.submit())

    #expect(await repository.savedSessions.first?.appearance.iconID == projectIcon("a").id)
  }
}

/// Answers per path, remembers what it was asked, and can be made slow.
private actor MappedFolders: WorkingDirectoryProbe {
  private let statuses: [String: WorkingDirectoryStatus]
  private let delay: Duration?
  private(set) var inspected: [String] = []

  init(_ statuses: [String: WorkingDirectoryStatus] = [:], delay: Duration? = nil) {
    self.statuses = statuses
    self.delay = delay
  }

  func inspect(path: String) async -> WorkingDirectoryStatus {
    inspected.append(path)
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return statuses[path] ?? .usable
  }
}

private func recent(_ paths: String...) -> [RecentFolder] {
  paths.map(RecentFolder.init(lexicalPath:))
}

@MainActor
@Suite("The recent folders of the new session sheet")
struct NewSessionRecentFolderTests {
  private func makeModel(
    recentFolders: [RecentFolder],
    probe: MappedFolders = MappedFolders(),
    budget: Duration = .seconds(5),
    fullDiskAccess: FullDiskAccessStatus? = .notGranted,
    templates: [PromptTemplate] = [],
    forgotten: @escaping @MainActor (RecentFolder) -> Void = { _ in }
  ) -> NewSessionModel {
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    return NewSessionModel(
      create: CreateSession(
        repository: SpyRepository(), agents: registry, folders: StubFolders(status: .usable)),
      registry: registry,
      fullDiskAccess: fullDiskAccess,
      templates: templates,
      recentFolders: recentFolders,
      folderProbe: probe,
      recentFolderProbeBudget: budget,
      forgetRecentFolder: forgotten
    )
  }

  @Test("Without any history the sheet opens as it always did")
  func noHistory() async {
    let model = makeModel(recentFolders: [])

    await model.load()

    #expect(model.draft.workingDirectoryPath == nil)
    #expect(model.recentFolders.isEmpty)
    #expect(model.hiddenRecentFolderCount == 0)
    #expect(model.preselectionNotice == nil)
  }

  @Test("The folder used last is in the field, and its card is the selected one")
  func lastFolderIsPreselected() async {
    let model = makeModel(recentFolders: recent("/work/api", "/work/web"))

    await model.load()

    #expect(model.draft.workingDirectoryPath == "/work/api")
    #expect(model.preselectedFolder == "/work/api")
    #expect(model.recentFolders.map { model.isSelected($0) } == [true, false])
    #expect(model.preselectionNotice == nil)
    // A default is not a problem to report before anything was asked for.
    #expect(model.issues.isEmpty)
  }

  @Test("A folder that has gone is not preselected: the next one is, and the sheet says so")
  func missingFolderIsSkipped() async {
    let probe = MappedFolders(["/work/gone": .missing])
    let model = makeModel(recentFolders: recent("/work/gone", "/work/web"), probe: probe)

    await model.load()

    #expect(model.draft.workingDirectoryPath == "/work/web")
    #expect(model.recentFolders.first?.availability == .missing)
    #expect(model.recentFolders.first?.name == "gone")
    #expect(model.preselectionNotice?.contains("gone") == true)

    // The remark is about the default; once the user picks, it has nothing left to say.
    await model.chooseRecentFolder(model.recentFolders[1])
    #expect(model.preselectionNotice == nil)
  }

  @Test("When every folder has gone, nothing is preselected")
  func everyFolderGone() async {
    let probe = MappedFolders(["/a": .missing, "/b": .notADirectory])
    let model = makeModel(recentFolders: recent("/a", "/b"), probe: probe)

    await model.load()

    #expect(model.draft.workingDirectoryPath == nil)
    #expect(model.recentFolders.allSatisfy { $0.availability == .missing })
  }

  @Test("A protected folder is never looked at without Full Disk Access, and still offered")
  func protectedFolderIsNotProbed() async {
    let documents = NSHomeDirectory() + "/Documents/api"
    let probe = MappedFolders()
    let model = makeModel(recentFolders: recent(documents, "/work/web"), probe: probe)

    await model.load()

    #expect(await probe.inspected == ["/work/web"])
    #expect(model.recentFolders.first?.availability == .unverified)
    #expect(model.draft.workingDirectoryPath == documents)
  }

  @Test("With Full Disk Access, a protected folder is looked at like any other")
  func protectedFolderIsProbedWithAccess() async {
    let documents = NSHomeDirectory() + "/Documents/api"
    let probe = MappedFolders()
    let model = makeModel(recentFolders: recent(documents), probe: probe, fullDiskAccess: .granted)

    await model.load()

    #expect(await probe.inspected == [documents])
    #expect(model.recentFolders.first?.availability == .available)
  }

  @Test("A folder too slow to answer is offered unverified, without holding the sheet")
  func slowFolderStaysUnverified() async {
    let probe = MappedFolders(["/slow": .missing], delay: .seconds(5))
    let model = makeModel(recentFolders: recent("/slow"), probe: probe, budget: .milliseconds(50))
    let clock = ContinuousClock()

    let elapsed = await clock.measure { await model.load() }

    #expect(elapsed < .seconds(2))
    #expect(model.recentFolders.first?.availability == .unverified)
    #expect(model.draft.workingDirectoryPath == "/slow")
  }

  @Test("A template with a folder wins over the preselection")
  func templateOpenedWithAFolder() async {
    var api = templateReview
    api.workingDirectoryPath = "~/Projects/api"
    let model = makeModel(recentFolders: recent("/work/web"), templates: [api])

    model.selectTemplate(api.id)
    await model.load()

    #expect(model.draft.workingDirectoryPath == "~/Projects/api")
    #expect(model.preselectedFolder == nil)
  }

  @Test("A template picked later replaces the preselected folder, and gives it back")
  func templatePickedAfterPreselection() async {
    var api = templateReview
    api.workingDirectoryPath = "~/Projects/api"
    let model = makeModel(recentFolders: recent("/work/web"), templates: [api, templateFeedback])
    await model.load()

    model.selectTemplate(api.id)
    #expect(model.draft.workingDirectoryPath == "~/Projects/api")

    // A template without a folder gives back the one that was there before.
    model.selectTemplate(templateFeedback.id)
    #expect(model.draft.workingDirectoryPath == "/work/web")
  }

  @Test("A folder the user picked is theirs: a template no longer replaces it")
  func chosenFolderIsNotReplacedByATemplate() async {
    var api = templateReview
    api.workingDirectoryPath = "~/Projects/api"
    let model = makeModel(recentFolders: recent("/work/web", "/work/app"), templates: [api])
    await model.load()

    await model.chooseRecentFolder(model.recentFolders[1])
    model.selectTemplate(api.id)

    #expect(model.draft.workingDirectoryPath == "/work/app")
    #expect(model.recentFolders.map { model.isSelected($0) } == [false, true])
  }

  @Test("Without Full Disk Access, a card of a protected folder fills the field unread")
  func protectedCardIsNotRead() async {
    let documents = NSHomeDirectory() + "/Documents/api"
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    let creationProbe = CountingFolders()
    let model = NewSessionModel(
      create: CreateSession(repository: SpyRepository(), agents: registry, folders: creationProbe),
      registry: registry,
      fullDiskAccess: .notGranted,
      recentFolders: recent("/work/web", documents),
      folderProbe: MappedFolders()
    )
    await model.load()

    await model.chooseRecentFolder(model.recentFolders[1])

    #expect(model.draft.workingDirectoryPath == documents)
    #expect(await creationProbe.count == 0)
    #expect(model.preselectedFolder == nil)
  }

  @Test("A card is checked like a folder handed back by the open panel")
  func clickingACardChecksTheFolder() async {
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    let model = NewSessionModel(
      create: CreateSession(
        repository: SpyRepository(), agents: registry, folders: StubFolders(status: .missing)),
      registry: registry,
      recentFolders: recent("/work/web", "/work/app"),
      folderProbe: MappedFolders()
    )
    await model.load()

    await model.chooseRecentFolder(model.recentFolders[1])

    #expect(model.draft.workingDirectoryPath == "/work/app")
    #expect(model.issues(for: .workingDirectory) == [.workingDirectoryNotFound])
  }

  @Test("Typing the path of a recent folder lights its card")
  func typedPathSelectsTheCard() async {
    let model = makeModel(recentFolders: recent("/work/web", "/work/app"))
    await model.load()

    model.draft.workingDirectoryPath = "/work/app/"

    #expect(model.recentFolders.map { model.isSelected($0) } == [false, true])
    model.draft.workingDirectoryPath = "/elsewhere"
    #expect(!model.recentFolders.contains { model.isSelected($0) })
  }

  @Test("Three cards, then Show More with the number of the others")
  func showMore() async {
    let model = makeModel(recentFolders: recent("/a", "/b", "/c", "/d", "/e"))
    await model.load()

    #expect(model.shownRecentFolders.map(\.folder.path) == ["/a", "/b", "/c"])
    #expect(model.hiddenRecentFolderCount == 2)

    model.isShowingMoreFolders = true
    #expect(model.shownRecentFolders.count == 5)
  }

  @Test("Three folders or fewer: no Show More")
  func noShowMoreForThree() async {
    let model = makeModel(recentFolders: recent("/a", "/b", "/c"))
    await model.load()

    #expect(model.shownRecentFolders.count == 3)
    #expect(model.hiddenRecentFolderCount == 0)
  }

  @Test("Remove from Recents takes the card away and tells the history")
  func forgettingAFolder() async throws {
    var forgotten: [RecentFolder] = []
    let model = makeModel(
      recentFolders: recent("/a", "/b", "/c", "/d"), forgotten: { forgotten.append($0) })
    await model.load()
    model.isShowingMoreFolders = true

    model.forget(try #require(model.recentFolders.last))

    #expect(model.recentFolders.map(\.folder.path) == ["/a", "/b", "/c"])
    #expect(forgotten.map(\.path) == ["/d"])
    #expect(!model.isShowingMoreFolders)
  }

  @Test("Removing the preselected folder empties the field rather than creating there")
  func forgettingThePreselectedFolder() async {
    let model = makeModel(recentFolders: recent("/work/api", "/work/web"))
    await model.load()

    model.forget(model.recentFolders[0])

    #expect(model.draft.workingDirectoryPath == nil)
    #expect(model.preselectedFolder == nil)
    #expect(!model.canSubmit)
  }

  @Test("Removing the folder that had gone takes its remark away, not the proposed one")
  func forgettingTheSkippedFolder() async {
    let probe = MappedFolders(["/work/gone": .missing])
    let model = makeModel(recentFolders: recent("/work/gone", "/work/web"), probe: probe)
    await model.load()

    model.forget(model.recentFolders[0])

    #expect(model.preselectionNotice == nil)
    #expect(model.draft.workingDirectoryPath == "/work/web")
  }

  @Test("A folder seeded by its spelling that links into Documents is never looked at")
  func linkIntoAProtectedFolderIsNotRead() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    // Dangling on purpose: the test must not open the real Documents folder either.
    let link = parent.appendingPathComponent("code").path
    try FileManager.default.createSymbolicLink(
      atPath: link, withDestinationPath: NSHomeDirectory() + "/Documents/\(UUID().uuidString)")
    let registry = StubRegistry(providers: [StubProvider(id: "claude-code", state: .available)])
    let creationProbe = CountingFolders()
    let probe = MappedFolders()
    let model = NewSessionModel(
      create: CreateSession(repository: SpyRepository(), agents: registry, folders: creationProbe),
      registry: registry,
      fullDiskAccess: .notGranted,
      recentFolders: recent(link, "/work/web"),
      folderProbe: probe
    )

    await model.load()
    await model.chooseRecentFolder(model.recentFolders[0])

    #expect(await probe.inspected == ["/work/web"])
    #expect(model.recentFolders.first?.availability == .unverified)
    #expect(model.draft.workingDirectoryPath == link)
    #expect(await creationProbe.count == 0)
  }

  @Test("Two folders of one name are told apart on their cards")
  func namesakesOnCards() {
    let model = makeModel(recentFolders: recent("/work/client-a/api", "/work/client-b/api"))

    #expect(model.recentFolders.map(\.name) == ["api — client-a", "api — client-b"])
    #expect(model.recentFolders.map(\.location) == ["/work/client-a", "/work/client-b"])
  }
}
