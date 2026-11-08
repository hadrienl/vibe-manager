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

  @Test("A file a drop received is moved to the session's drops; any other stays the original")
  func receivedDropsAreKept() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(CreateSession.receivedDropsFolder, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let received = temporary.appendingPathComponent("shot.png")
    try Data("a".utf8).write(to: received)
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("kept-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: kept) }
    let drops = CopyingDropStore(destination: kept)
    let create = CreateSession(
      repository: SpyRepository(), agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(), drops: drops)
    let original = URL(fileURLWithPath: "/workspace/plan.md")
    var draft = draft(prompt: "Look at")
    draft.attachments = [received, original]

    let creation = try await create(draft)

    #expect(creation.firstMessage?.attachments == [kept, original])
    #expect(creation.session.initialPrompt.contains(kept.lastPathComponent))
    #expect(!creation.session.initialPrompt.contains("shot.png"))
    #expect(await drops.keptFor == [creation.session.id])
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
  }

  @Test("Every file of one drop is kept, not only the first: they share its folder")
  func everyFileOfADropIsKept() async throws {
    let (temporary, received) = try receivedDrop(named: ["one.png", "two.png"])
    let kept = (1...2).map {
      FileManager.default.temporaryDirectory.appendingPathComponent("kept-\($0)-\(UUID()).png")
    }
    defer { kept.forEach { try? FileManager.default.removeItem(at: $0) } }
    let create = CreateSession(
      repository: SpyRepository(), agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(),
      drops: CopyingDropStore(destinations: kept))
    var draft = draft(prompt: "Compare")
    draft.attachments = received

    let creation = try await create(draft)

    #expect(creation.firstMessage?.attachments == kept)
    #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
  }

  @Test("A file of a drop that cannot be kept stays readable where it was received")
  func aDropThatCannotBeKeptStays() async throws {
    let (temporary, received) = try receivedDrop(named: ["one.png", "two.png"])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("kept-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: kept) }
    let create = CreateSession(
      repository: SpyRepository(), agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(),
      drops: CopyingDropStore(destination: kept))
    var draft = draft(prompt: "Compare")
    draft.attachments = received

    let creation = try await create(draft)

    #expect(creation.firstMessage?.attachments == [kept, received[1]])
    #expect(FileManager.default.fileExists(atPath: received[1].path))
  }

  /// Files received by one drop: all in one folder of the temporary folder, as the catcher does.
  private func receivedDrop(named names: [String]) throws -> (folder: URL, files: [URL]) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(CreateSession.receivedDropsFolder, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = names.map { folder.appendingPathComponent($0) }
    for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
    return (folder, files)
  }

  @Test("The tickets the fields name are recognised, and the first one becomes the ticket (#89)")
  func ticketsAreRecognised() async throws {
    let repository = SpyRepository()
    let create = CreateSession(
      repository: repository, agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(),
      ticketResolvers: { TicketResolverSet(TicketResolverPresets.all) })
    var template = PromptTemplate(name: "Review", body: "Review {{url}}, see {{other}}.")
    template.revision = 1
    var draft = draft(name: "PROJ-1 https://acme.atlassian.net/browse/PROJ-1", prompt: "")
    draft.templateFill = PromptTemplateFill(
      template: template,
      values: [
        "url": "https://github.com/acme/app/pull/12", "other": "https://example.com/not-a-ticket",
      ])

    let creation = try await create(draft)

    #expect(creation.tickets.map(\.shortID) == ["PROJ-1", "acme/app#12"])
    let stored = await repository.savedSessions.first?.ticket
    #expect(
      stored
        == SessionTicket(
          url: URL(string: "https://acme.atlassian.net/browse/PROJ-1")!, source: .detected))
  }

  @Test("A ticket typed in its field is kept, and still read first")
  func typedTicketIsKept() async throws {
    let repository = SpyRepository()
    let create = CreateSession(
      repository: repository, agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(),
      ticketResolvers: { TicketResolverSet(TicketResolverPresets.all) })
    var draft = draft(prompt: "Also https://github.com/acme/app/issues/2")
    draft.ticketText = "https://github.com/acme/app/issues/1"

    let creation = try await create(draft)

    #expect(creation.tickets.map(\.shortID) == ["acme/app#1", "acme/app#2"])
    #expect(creation.session.ticket?.source == .manual)
  }

  @Test("Titles off: nothing is recognised and no ticket is deduced")
  func titlesOff() async throws {
    let repository = SpyRepository()
    let create = CreateSession(
      repository: repository, agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable), clock: FixedClock(), ticketResolvers: { nil })

    let creation = try await create(draft(prompt: "https://github.com/acme/app/issues/1"))

    #expect(creation.tickets.isEmpty)
    #expect(creation.session.ticket == nil)
  }

  @Test("A valid draft is stored once, with the plan that will be launched")
  func validDraftIsStored() async throws {
    let (create, repository) = makeSubject()

    let creation = try await create(draft())

    #expect(creation.session.name == "Refactor the webhook")
    #expect(creation.session.status == .closed)
    #expect(creation.plan.workingDirectoryPath == "/workspace")
    #expect(await repository.savedSessions.count == 1)
  }

  @Test("A session started in a worktree records its repository; one in a clone, nothing (#525)")
  func worktreeRecordsItsRepository() async throws {
    let repository = SpyRepository()
    let create = CreateSession(
      repository: repository,
      agents: StubRegistry(providers: [StubProvider()]),
      folders: StubFolders(status: .usable),
      clock: FixedClock(),
      worktreeRepository: { $0 == "/w/mairie/.claude/worktrees/TICKET-185" ? "/w/mairie" : nil }
    )

    let child = try await create(draft(path: "/w/mairie/.claude/worktrees/TICKET-185"))
    let clone = try await create(draft(path: "/w/mairie"))

    #expect(child.session.repositories.first?.path == "/w/mairie/.claude/worktrees/TICKET-185")
    #expect(child.session.repositories.first?.mainRepositoryPath == "/w/mairie")
    #expect(clone.session.repositories.first?.mainRepositoryPath == nil)
    #expect(
      await repository.savedSessions.first?.repositories.first?.mainRepositoryPath == "/w/mairie")
  }

  @Test("The effort chosen in the draft is launched with, and kept on the session (#411)")
  func draftEffortIsLaunched() async throws {
    let (create, _) = makeSubject()
    var withEffort = draft()
    withEffort.effort = "high"

    let creation = try await create(withEffort)

    #expect(creation.plan.arguments == ["--effort", "high"])
    #expect(creation.session.agent?.effort == "high")
    #expect(try await create(draft()).plan.arguments.isEmpty)
  }

  @Test("A session made from a template keeps the rendered prompt and where it came from")
  func templateSessionKeepsRenderedPrompt() async throws {
    let (create, repository) = makeSubject()
    var template = PromptTemplate(name: "Review", body: "Review {{url}} now.")
    template.revision = 3
    var draft = draft(prompt: "")
    draft.templateFill = PromptTemplateFill(template: template, values: ["url": "https://x/1"])

    let creation = try await create(draft)

    #expect(creation.session.initialPrompt == "Review https://x/1 now.")
    #expect(
      creation.session.template
        == PromptTemplateReference(
          id: template.id.description, name: "Review", revision: "3"))
    #expect(creation.plan.promptDelivery == .argument)
    #expect(await repository.savedSessions.first?.initialPrompt == "Review https://x/1 now.")
  }

  @Test("A required template field left empty stops the creation, and nothing is written")
  func missingTemplateFieldStopsCreation() async {
    let (create, repository) = makeSubject()
    var draft = draft(prompt: "")
    draft.templateFill = PromptTemplateFill(
      template: PromptTemplate(name: "Review", body: "Review {{url}}."))

    await #expect(throws: SessionCreationRejected.self) {
      try await create(draft)
    }
    let problems = await create.problems(with: draft)
    #expect(problems.map(\.fieldKey) == ["url"])
    #expect(await repository.savedSessions.isEmpty)
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

  @Test("With files joined, the agent starts without a prompt, which becomes its first message")
  func attachmentsMakeAFirstMessage() async throws {
    let (create, _) = makeSubject()
    var withFiles = draft(prompt: "Look at\n")
    let image = FileManager.default.temporaryDirectory.appendingPathComponent("Capture d’écran.png")
    withFiles.attachments = [image]

    let creation = try await create(withFiles)

    #expect(creation.plan.promptDelivery == .none)
    #expect(creation.firstMessage == PromptSubmission(text: "Look at", attachments: [image]))
    // What the session keeps, and starts with again, holds the files' paths.
    #expect(creation.session.initialPrompt == "Look at " + ShellPath.escaped(image.path))
  }

  @Test("With files joined, a prompt the agent would refuse is still reported")
  func attachmentsKeepThePromptChecked() async {
    var provider = StubProvider()
    provider.promptFailure = .promptTooLarge(byteCount: 10, limit: 5)
    let (create, repository) = makeSubject(provider: provider)
    var withFiles = draft()
    withFiles.attachments = [FileManager.default.temporaryDirectory.appendingPathComponent("a.png")]

    await #expect(throws: SessionCreationRejected.self) { try await create(withFiles) }
    #expect(await repository.savedSessions.isEmpty)
  }

  @Test("Without files, the prompt is the agent's argument and there is no first message")
  func noAttachmentsNoFirstMessage() async throws {
    let (create, _) = makeSubject()

    let creation = try await create(draft())

    #expect(creation.plan.promptDelivery == .argument)
    #expect(creation.firstMessage == nil)
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
  /// Refused only for a launch that carries a prompt.
  var promptFailure: AgentLaunchError?

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
    if let promptFailure, request.initialPrompt != nil { throw promptFailure }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      // As the real agents do: the level is an argument of the launch (#411).
      arguments: request.effort.map { ["--effort", $0] } ?? [],
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

/// Copies the n-th file it is given to the n-th destination; with no destination left, fails.
private actor CopyingDropStore: SessionDropStore {
  let destinations: [URL]
  private(set) var keptFor: [SessionID] = []

  init(destination: URL) { self.init(destinations: [destination]) }
  init(destinations: [URL]) { self.destinations = destinations }

  func save(_: Data, suggestedName _: String, for _: SessionID) throws -> URL { destinations[0] }
  func copy(_ file: URL, suggestedName _: String, for id: SessionID) throws -> URL {
    guard keptFor.count < destinations.count else { throw CocoaError(.fileWriteOutOfSpace) }
    let destination = destinations[keptFor.count]
    keptFor.append(id)
    try FileManager.default.copyItem(at: file, to: destination)
    return destination
  }
  func remove(_: SessionID) {}
  func sweep(keeping _: Set<SessionID>) {}
}
