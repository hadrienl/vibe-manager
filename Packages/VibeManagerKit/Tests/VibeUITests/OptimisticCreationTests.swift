import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Creating a session without waiting for it", .timeLimit(.minutes(2)))
struct OptimisticCreationTests {
  private let folder = FileManager.default.temporaryDirectory.path

  private func existing() -> WorkSession {
    SessionDraft(name: "Existing", providerID: "stub", workingDirectoryPath: folder).session()
  }

  private func makeModel(_ repository: GatedRepository) async -> AppModel {
    let launcher = SessionLauncher(
      supervisor: FakeSupervisor(), repository: repository, agents: OneAgent(),
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: OneAgent(), launcher: launcher)
    await model.load()
    return model
  }

  private func openSheet(in model: AppModel, name: String, folder: String) throws
    -> NewSessionModel
  {
    model.beginNewSession()
    let sheet = try #require(model.newSessionModel)
    sheet.draft = SessionDraft(name: name, providerID: "stub", workingDirectoryPath: folder)
    return sheet
  }

  @Test("Create closes the sheet and shows the session to come before it is even stored")
  func placeholderComesFirst() async throws {
    let previous = existing()
    let repository = GatedRepository(sessions: [previous])
    let model = await makeModel(repository)
    model.select(previous.id)
    _ = try openSheet(in: model, name: "Brand new", folder: folder)

    model.submitNewSession(launching: true)

    #expect(!model.isPresentingNewSession)
    #expect(model.shownCreation?.name == "Brand new")
    #expect(model.shownCreation?.phase == .saving)
    #expect(model.creationRow?.name == "Brand new")

    await repository.open()
    await waitUntil("the creation is over") { model.sessionInCreation == nil }
    let created = try #require(model.sessions.first { $0.name == "Brand new" })
    #expect(model.selectedSessionID == created.id)
    #expect(model.pane(for: created.id) != nil)
    #expect(model.shownCreation == nil)
    #expect(model.creationRow == nil)
  }

  @Test("A draft refused after the sheet closed brings the sheet back, with its problems")
  func refusalReopensTheSheet() async throws {
    let previous = existing()
    let repository = GatedRepository(sessions: [previous], open: true)
    let model = await makeModel(repository)
    model.select(previous.id)
    let sheet = try openSheet(in: model, name: "Nowhere", folder: "/nonexistent/\(UUID())")

    model.submitNewSession(launching: true)
    await waitUntil("the creation is over") { model.sessionInCreation == nil }

    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel === sheet)
    #expect(sheet.draft.name == "Nowhere")
    #expect(sheet.issues.contains(.workingDirectoryNotFound))
    #expect(model.sessions.map(\.id) == [previous.id])
    #expect(model.selectedSessionID == previous.id)
  }

  @Test("A session selected while the new one is made stays on screen when it is ready")
  func goingElsewhereIsKept() async throws {
    let first = existing()
    let second = existing()
    let repository = GatedRepository(sessions: [first, second])
    let model = await makeModel(repository)
    model.select(first.id)
    _ = try openSheet(in: model, name: "Later", folder: folder)

    model.submitNewSession(launching: true)
    // A row the sidebar shows: sessions that never ran are in To Do.
    model.setColumn(.todo)
    model.select(second.id)

    #expect(model.shownCreation == nil)
    // Still in the sidebar: it is being made, whatever is on screen.
    #expect(model.creationRow?.name == "Later")

    await repository.open()
    await waitUntil("the creation is over") { model.sessionInCreation == nil }
    #expect(model.sessions.contains { $0.name == "Later" })
    #expect(model.selectedSessionID == second.id)
  }

  @Test("A second Create while the first is on its way waits in its sheet, and leaves it alone")
  func secondCreationWaitsInItsSheet() async throws {
    let repository = GatedRepository(sessions: [])
    let model = await makeModel(repository)
    _ = try openSheet(in: model, name: "First", folder: folder)
    model.submitNewSession(launching: true)
    _ = try openSheet(in: model, name: "Second", folder: folder)

    model.submitNewSession(launching: true)

    #expect(model.isPresentingNewSession)
    #expect(model.sessionInCreation?.name == "First")

    await repository.open()
    await waitUntil("the creation is over") { model.sessionInCreation == nil }
    await waitUntil("both sessions are listed") { model.sessions.count >= 2 }
    #expect(Set(model.sessions.map(\.name)) == ["First", "Second"])
    #expect(!model.isPresentingNewSession)
  }

  /// A model whose agents wait for their terminal to be measured, which nothing does until
  /// `startAgent(of:in:)`: the creation stays in its `.starting` phase meanwhile.
  private func makeModelWithHeldAgents(recentFolders: RecentFolders? = nil) async -> AppModel {
    let repository = GatedRepository(sessions: [], open: true)
    let launcher = SessionLauncher(
      supervisor: FakeSupervisor(), repository: repository, agents: OneAgent(),
      viewportTimeout: .seconds(600))
    let model = AppModel(
      repository: repository, agents: OneAgent(), launcher: launcher,
      recentFolderStore: InMemoryRecentFolderStore(recentFolders))
    await model.load()
    return model
  }

  private func startAgent(of id: SessionID, in model: AppModel) async {
    await waitUntil("its terminal is made") { model.pane(for: id) != nil }
    await model.pane(for: id)?.reportViewportSize(TerminalSize(columns: 80, rows: 24))
    await waitUntil("the creation is over") { model.sessionInCreation == nil }
  }

  @Test("The folder of a session whose agent is starting is proposed again at once")
  func folderIsOfferedBeforeTheAgentRuns() async throws {
    let model = await makeModelWithHeldAgents()
    _ = try openSheet(in: model, name: "First", folder: folder)

    model.submitNewSession(launching: true)
    await waitUntil("the session is stored and its agent starting") {
      model.sessionInCreation?.phase == .starting
    }
    model.beginNewSession()
    let next = try #require(model.newSessionModel)

    #expect(next.recentFolders.map(\.folder.path) == [folder])
    // Offered, not yet in the history.
    #expect(model.recentFolders.entries.isEmpty)

    await startAgent(of: try #require(model.sessionInCreation?.sessionID), in: model)
    // Resolved and written once the agent runs, and the note gone.
    await waitUntil("the folder is written under its identity") {
      await model.recentFolderStore.load()?.entries.map(\.key) == [CanonicalPath.of(folder)]
    }
    #expect(model.recentFolders.entries.count == 1)
    #expect(model.notedFolder == nil)
  }

  @Test("A folder noted meanwhile neither doubles an equivalent spelling nor pushes a folder out")
  func notedFolderLosesNothing() async throws {
    // A folder reached through a link: two spellings of one folder, as `/tmp` and `/private/tmp`.
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("NotedFolder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("link").path
    try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: real.path)
    let canonical = CanonicalPath.of(folder)
    try #require(canonical != RecentFolder.lexicalKey(of: folder))
    let others = (0..<(RecentFolders.limit - 1)).map { RecentFolder(lexicalPath: "/work/\($0)") }
    let full = RecentFolders([RecentFolder(path: canonical, key: canonical)] + others)
    #expect(full.entries.count == RecentFolders.limit)
    let model = await makeModelWithHeldAgents(recentFolders: full)
    _ = try openSheet(in: model, name: "Again", folder: folder)

    model.submitNewSession(launching: true)
    await waitUntil("the noted folder is resolved") { model.notedFolder?.key == canonical }
    model.beginNewSession()
    let next = try #require(model.newSessionModel)

    let offered = next.recentFolders.map(\.folder.key)
    #expect(offered == [canonical] + others.map(\.key))
    #expect(model.recentFolders == full)

    await startAgent(of: try #require(model.sessionInCreation?.sessionID), in: model)
    await waitUntil("the folder is written again") {
      await model.recentFolderStore.load()?.entries.first?.path == folder
    }
    let written = try #require(await model.recentFolderStore.load())
    #expect(written.entries.map(\.key) == [canonical] + others.map(\.key))
  }

  @Test("A draft that fails its own checks keeps the sheet open")
  func localProblemsStayInTheSheet() async throws {
    let repository = GatedRepository(sessions: [], open: true)
    let model = await makeModel(repository)
    let sheet = try openSheet(in: model, name: "Relative", folder: "relative/path")

    #expect(await sheet.refusesBeforeCreating())
    #expect(!sheet.issues.isEmpty)
    #expect(model.isPresentingNewSession)
    #expect(model.sessionInCreation == nil)
  }
}

@MainActor
@Suite("The new session's draft, in the main area (#177)", .timeLimit(.minutes(2)))
struct NewSessionDraftTests {
  private let folder = FileManager.default.temporaryDirectory.path

  private func makeModel(sessions: [WorkSession]) async -> AppModel {
    let repository = GatedRepository(sessions: sessions, open: true)
    let launcher = SessionLauncher(
      supervisor: FakeSupervisor(), repository: repository, agents: OneAgent(),
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: OneAgent(), launcher: launcher)
    await model.load()
    return model
  }

  private func existing() -> WorkSession {
    SessionDraft(name: "Existing", providerID: "stub", workingDirectoryPath: folder).session()
  }

  @Test("⌘N shows the draft over the session, which stays selected, and the list shows none")
  func draftCoversTheSession() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)

    model.beginNewSession()

    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel != nil)
    #expect(model.selectedSessionID == previous.id)
    #expect(model.selectedSessionIDs.isEmpty)
    #expect(!model.isSessionOnScreen)
    #expect(!model.canTogglePresentation)
  }

  @Test("Going to a session sets a draft with something in it aside, and ⌘N brings it back")
  func writtenDraftIsKept() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft.initialPrompt = "Half a thought"

    model.select(previous.id)

    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)

    model.beginNewSession()
    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)
    #expect(draft.draft.initialPrompt == "Half a thought")
  }

  @Test("An empty draft left for a session goes: there is nothing to come back to")
  func pristineDraftGoes() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    model.beginNewSession()

    // The session underneath, picked in the list: it is where the user goes.
    model.selectFromList([previous.id])

    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel == nil)
    #expect(model.selectedSessionIDs == [previous.id])
  }

  @Test("The list clearing its selection under the draft does not leave it")
  func emptyListSelectionKeepsTheDraft() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    model.beginNewSession()

    model.selectFromList([])

    #expect(model.isPresentingNewSession)
    #expect(model.selectedSessionID == previous.id)
  }

  @Test("A selection the application moves by itself leaves the draft on screen")
  func automaticSelectionKeepsTheDraft() async throws {
    let first = existing()
    let second = existing()
    let model = await makeModel(sessions: [first, second])
    model.beginNewSession()

    model.select(second.id, leavingDraft: false)

    #expect(model.isPresentingNewSession)
    #expect(model.selectedSessionID == second.id)
  }

  @Test("Files chosen over the draft join its prompt, not the session underneath")
  func attachedFilesGoToTheDraft() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)

    #expect(model.canAttachFiles)
    await model.attachChosenFiles([URL(fileURLWithPath: "/tmp/notes.md")])

    #expect(draft.draft.attachments == [URL(fileURLWithPath: "/tmp/notes.md")])
  }

  @Test("Open Quickly leaves the draft for the session chosen")
  func openQuicklyLeavesTheDraft() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.beginNewSession()
    try #require(model.newSessionModel).draft.initialPrompt = "Kept"

    model.goToSession(previous.id)

    #expect(!model.isPresentingNewSession)
    #expect(model.selectedSessionID == previous.id)
    #expect(model.newSessionModel != nil)
  }

  @Test("Nothing of the session underneath is within reach of the menus")
  func hiddenSessionIsOutOfReach() async throws {
    let first = existing()
    let second = existing()
    let model = await makeModel(sessions: [first, second])
    model.select(second.id)
    model.beginNewSession()

    #expect(model.selectedBrowser == nil)
    #expect(model.selectedGroup == nil)
    #expect(!model.canMoveSelection(by: -1))
    #expect(!model.terminalClaimsKeyboardOnActivation)
  }

  @Test("A refused draft comes back over an empty one begun meanwhile, unnamed again")
  func refusedDraftWinsOverAnEmptyOne() async throws {
    let model = await makeModel(sessions: [])
    model.beginNewSession()
    let refused = try #require(model.newSessionModel)
    refused.draft = SessionDraft(
      initialPrompt: "Somewhere gone", providerID: "stub",
      workingDirectoryPath: "/nonexistent/\(UUID())")

    model.submitNewSession(launching: true)
    model.beginNewSession()
    #expect(model.newSessionModel !== refused)
    await waitUntil("the creation is over") { model.sessionInCreation == nil }

    #expect(model.newSessionModel === refused)
    #expect(model.isPresentingNewSession)
    #expect(refused.draft.initialPrompt == "Somewhere gone")
    #expect(refused.draft.name.isEmpty)
  }

  @Test("A folder asked for over a draft with something in it starts another; both are kept")
  func folderStartsAnotherDraft() async throws {
    let model = await makeModel(sessions: [])
    model.beginNewSession()
    let first = try #require(model.newSessionModel)
    first.draft.initialPrompt = "First"

    model.beginNewSession(folder: folder)

    let second = try #require(model.newSessionModel)
    #expect(second !== first)
    #expect(model.setAsideDrafts.first === first)
    #expect(model.newSessionDrafts.count == 2)

    // Its row brings the first back; the second, changed by its folder, is put aside in turn.
    await waitUntil("the folder is in the second draft") {
      second.draft.workingDirectoryPath == folder
    }
    model.showNewSessionDraft(first)
    #expect(model.newSessionModel === first)
    #expect(model.setAsideDrafts.first === second)
  }

  @Test("The + of a group opens the draft on its folder and leaves the selection alone (#106)")
  func groupButtonPreselectsItsFolder() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    let group = SessionGroup(
      id: SessionFolderKey(path: folder), folderName: "tmp", displayPath: folder,
      sessions: [previous])

    model.beginNewSession(in: group)

    let draft = try #require(model.newSessionModel)
    #expect(model.isPresentingNewSession)
    #expect(model.selectedSessionID == previous.id)
    await waitUntil("the group's folder is in the draft") {
      draft.draft.workingDirectoryPath == folder
    }
  }

  @Test("The + of a group whose folder is gone opens nothing")
  func groupButtonOnAMissingFolder() async throws {
    let model = await makeModel(sessions: [])
    let group = SessionGroup(
      id: SessionFolderKey(path: "/nowhere/gone"), folderName: "gone",
      displayPath: "/nowhere/gone", isMissing: true, sessions: [])

    model.beginNewSession(in: group)

    #expect(model.newSessionModel == nil)
    #expect(!model.isPresentingNewSession)
  }

  @Test("A draft nothing was changed in takes the folder asked for")
  func pristineDraftTakesTheFolder() async throws {
    let model = await makeModel(sessions: [])
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)

    model.beginNewSession(folder: folder)

    #expect(model.newSessionModel === draft)
    #expect(model.setAsideDrafts.isEmpty)
  }

  @Test("Sent without a name, the session is named after its prompt")
  func unnamedDraftIsNamedAfterItsPrompt() async throws {
    let model = await makeModel(sessions: [])
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft = SessionDraft(
      initialPrompt: "Fix the blank conversation", providerID: "stub",
      workingDirectoryPath: folder)

    model.submitNewSession(launching: false)

    #expect(model.creationRow?.name == "Fix the blank conversation")
    await waitUntil("the session is stored") { model.sessionInCreation == nil }
    #expect(model.sessions.contains { $0.name == "Fix the blank conversation" })
  }

  // MARK: - Escape (#293)

  @Test("Escape on an empty draft discards it, and leaves nothing to undo")
  func escapeDiscardsAnEmptyDraft() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    model.beginNewSession()
    let undo = UndoManager()

    model.discardNewSessionDraft(undoManager: undo)

    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel == nil)
    #expect(model.newSessionDrafts.isEmpty)
    #expect(model.selectedSessionID == previous.id)
    #expect(!undo.canUndo)
  }

  @Test("Escape on a draft written in discards it, and ⌘Z brings it back as it was")
  func escapeDiscardsAWrittenDraftUndoably() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.select(previous.id)
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft.name = "Parser"
    draft.draft.initialPrompt = "Rewrite the parser"
    let undo = UndoManager()

    model.discardNewSessionDraft(undoManager: undo)

    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionDrafts.isEmpty)
    #expect(model.selectedSessionID == previous.id)
    #expect(undo.undoActionName == String(localized: "Discard Draft", bundle: .module))

    let request = model.newSessionFocusRequest
    undo.undo()

    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)
    #expect(draft.draft.name == "Parser")
    #expect(draft.draft.initialPrompt == "Rewrite the parser")
    #expect(model.newSessionFocusRequest == request + 1)

    // ⇧⌘Z discards it again.
    undo.redo()
    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel == nil)
  }

  @Test("⌘Z over a draft begun since puts that one aside, and brings the discarded one back")
  func undoPutsTheCurrentDraftAside() async throws {
    let model = await makeModel(sessions: [])
    model.beginNewSession()
    let discarded = try #require(model.newSessionModel)
    discarded.draft.initialPrompt = "First"
    let undo = UndoManager()
    model.discardNewSessionDraft(undoManager: undo)
    model.beginNewSession()
    let current = try #require(model.newSessionModel)
    current.draft.initialPrompt = "Second"

    undo.undo()

    #expect(model.newSessionModel === discarded)
    #expect(model.setAsideDrafts.first === current)

    // Another draft brought on screen since: ⇧⌘Z leaves it alone.
    model.showNewSessionDraft(current)
    undo.redo()
    #expect(model.newSessionModel === current)
    #expect(model.isPresentingNewSession)
  }

  @Test("Escape does nothing to a draft on its way to becoming a session")
  func escapeLeavesASubmittingDraft() async throws {
    // Held at the store: the first creation is on its way, and the second waits in its draft.
    let repository = GatedRepository(sessions: [])
    let launcher = SessionLauncher(
      supervisor: FakeSupervisor(), repository: repository, agents: OneAgent(),
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: OneAgent(), launcher: launcher)
    await model.load()
    model.beginNewSession()
    try #require(model.newSessionModel).draft = SessionDraft(
      name: "First", providerID: "stub", workingDirectoryPath: folder)
    model.submitNewSession(launching: true)
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft = SessionDraft(name: "Second", providerID: "stub", workingDirectoryPath: folder)
    model.submitNewSession(launching: true)
    await waitUntil("the second draft is on its way") { draft.isSubmitting }
    let undo = UndoManager()

    model.discardNewSessionDraft(undoManager: undo)

    #expect(model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)
    #expect(!undo.canUndo)
    await repository.open()
    await waitUntil("both sessions are made") { model.sessions.count == 2 }
  }

  @Test("Going to another session, or Open Quickly, still sets a written draft aside")
  func goingElsewhereStillSetsTheDraftAside() async throws {
    let previous = existing()
    let model = await makeModel(sessions: [previous])
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft.initialPrompt = "Kept"

    model.select(previous.id)
    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)

    model.showNewSessionDraft()
    model.goToSession(previous.id)
    #expect(!model.isPresentingNewSession)
    #expect(model.newSessionModel === draft)

    // ⌘N on a folder over it: put aside, not discarded.
    model.showNewSessionDraft()
    model.beginNewSession(folder: folder)
    #expect(model.setAsideDrafts.first === draft)
  }

}

/// Holds every write until it is opened, so what the window shows meanwhile can be looked at.
private actor GatedRepository: SessionRepository {
  private var stored: [WorkSession]
  private var isOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(sessions: [WorkSession], open: Bool = false) {
    stored = sessions
    isOpen = open
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) async {
    if !isOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private struct OneAgent: AgentProviderResolving, AgentProvider {
  var descriptor: AgentDescriptor {
    AgentDescriptor(
      id: AgentProviderID("stub"), displayName: "Stub",
      capabilities: AgentCapabilities(
        supportsModelSelection: false, supportsInitialPrompt: true, supportsResume: false))
  }

  func descriptors() async -> [AgentDescriptor] { [descriptor] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    id == descriptor.id ? self : nil
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    [descriptor.id: await availability(forceRefresh: forceRefresh)]
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "Ready.", probedAt: Date(timeIntervalSince1970: 0), remediations: []))
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: descriptor.id, executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: request.workingDirectoryPath, promptDelivery: .none)
  }
}

private actor FakeSupervisor: TerminalSupervisor {
  private var sessions: [TerminalID: FakeTerminal] = [:]

  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    let session = FakeTerminal(id: id)
    sessions[id] = session
    return session
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: TerminalID, gracePeriod: Duration) {}

  func stopAll(gracePeriod: Duration) {}
}

private actor FakeTerminal: TerminalSession {
  nonisolated let id: TerminalID

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    TerminalAttachment(
      state: .running(processIdentifier: 4242),
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: AsyncStream { $0.finish() })
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 4242) }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {}

  func kill() {}
}
