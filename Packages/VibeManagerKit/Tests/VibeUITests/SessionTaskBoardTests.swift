import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The sidebar as a task board")
struct SessionTaskBoardTests {
  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-board-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// A session that ran and is stopped, in the column given.
  private func session(
    _ name: String, in column: SessionTaskStatus = .doing, updatedAt seconds: TimeInterval = 100,
    path: String = "/workspace", status: SessionStatus = .closed, resumable: Bool = true
  ) -> WorkSession {
    let date = Date(timeIntervalSince1970: seconds)
    return WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      // A conversation to resume, so that a restart starts without a summary to confirm.
      agent: SessionAgentConfiguration(
        providerID: "stub", resumeIdentifier: resumable ? "kept-identifier" : nil),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: date,
      closedAt: status == .closed ? date : nil,
      startedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)],
      taskStatus: column
    )
  }

  private func makeWorkspace(
    _ sessions: [WorkSession], supervisor: WorkspaceSupervisor = WorkspaceSupervisor()
  ) -> (AppModel, SessionLauncher, WorkspaceRepository) {
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    return (model, launcher, repository)
  }

  // MARK: - Moving

  @Test("A moved session leaves the column, which stays on screen, and the next row is selected")
  func movingKeepsTheColumn() async {
    let first = session("First", updatedAt: 300)
    let second = session("Second", updatedAt: 200)
    let third = session("Third", updatedAt: 100)
    let (model, _, repository) = makeWorkspace([first, second, third])
    await model.load()
    model.select(second.id)

    await model.setTaskStatus(.waiting, for: second.id)

    #expect(await repository.session(id: second.id)?.taskStatus == .waiting)
    #expect(model.filter.column == .doing)
    #expect(model.visibleSessions.map(\.id) == [first.id, third.id])
    // The row that took its place.
    #expect(model.selectedSessionID == third.id)
    #expect(model.summary(of: .waiting).count == 1)
  }

  @Test("Moving the last row of a column selects the one above it")
  func movingTheLastRow() async {
    let first = session("First", updatedAt: 200)
    let last = session("Last", updatedAt: 100)
    let (model, _, _) = makeWorkspace([first, last])
    await model.load()
    model.select(last.id)

    await model.setTaskStatus(.done, for: last.id)

    #expect(model.selectedSessionID == first.id)
  }

  @Test("Moving the only row of a column keeps it selected")
  func movingTheOnlyRow() async {
    let only = session("Only")
    let (model, _, _) = makeWorkspace([only])
    await model.load()
    model.select(only.id)

    await model.setTaskStatus(.waiting, for: only.id)

    #expect(model.visibleSessions.isEmpty)
    #expect(model.selectedSessionID == only.id)
  }

  @Test("Archiving the only row of Done keeps it selected")
  func archivingTheOnlyRow() async {
    let only = session("Only", in: .done)
    let (model, _, _) = makeWorkspace([only])
    await model.load()
    model.setColumn(.done)
    model.select(only.id)

    await model.archive(only.id)

    #expect(model.selectedSessionID == only.id)
  }

  @Test("⌥⌘→ and ⌥⌘← move one status at a time, and never archive")
  func shortcutsStepOneStatus() async {
    let subject = session("Subject", in: .waiting)
    let (model, _, repository) = makeWorkspace([subject])
    await model.load()

    await model.moveTaskStatus(of: subject.id, forward: true)
    #expect(await repository.session(id: subject.id)?.taskStatus == .done)

    await model.moveTaskStatus(of: subject.id, forward: true)
    #expect(await repository.session(id: subject.id)?.taskStatus == .done)
    #expect(model.pendingArchive == nil)

    await model.moveTaskStatus(of: subject.id, forward: false)
    #expect(await repository.session(id: subject.id)?.taskStatus == .waiting)
  }

  @Test("Archive from the swipe archives a session where nothing runs, at once (#115)")
  func archivingAnIdleSessionAsksNothing() async {
    let subject = session("Subject", in: .done)
    let (model, _, repository) = makeWorkspace([subject])
    await model.load()

    await model.setTaskStatus(.archived, for: subject.id)

    #expect(model.pendingArchive == nil)
    #expect(await repository.session(id: subject.id)?.taskStatus == .archived)
    #expect(model.archivedSessions.map(\.id) == [subject.id])
  }

  @Test("Archive from the swipe asks first when the agent runs, as the command does")
  func archivingARunningSessionAsks() async {
    let subject = session("Subject", in: .done, path: folder())
    let (model, launcher, repository) = makeWorkspace([subject])
    await model.load()
    await model.refreshResolutions()
    await model.restart(subject.id)
    #expect(launcher.isRunning(subject.id))

    await model.setTaskStatus(.archived, for: subject.id)

    #expect(model.pendingArchive?.id == subject.id)
    #expect(await repository.session(id: subject.id)?.taskStatus != .archived)

    await model.archive(subject.id)
    #expect(await repository.session(id: subject.id)?.taskStatus == .archived)
    #expect(!launcher.isRunning(subject.id))
  }

  @Test("⌃⌘A pressed again and again empties a column, in the order it is drawn (#115)")
  func archivingInABurst() async {
    let first = session("First", in: .done, updatedAt: 300)
    let second = session("Second", in: .done, updatedAt: 200)
    let third = session("Third", in: .done, updatedAt: 100)
    let other = session("Other", in: .waiting)
    let (model, _, repository) = makeWorkspace([first, second, third, other])
    await model.load()
    model.setColumn(.done)
    model.select(first.id)

    var archived: [SessionID] = []
    for _ in 0..<3 {
      guard let selected = model.selectedSession, model.canArchive(selected) else { break }
      archived.append(selected.id)
      await model.requestArchive(selected.id)
    }

    #expect(archived == [first.id, second.id, third.id])
    #expect(model.pendingArchive == nil)
    #expect(model.visibleSessions.isEmpty)
    // The column is empty: the key has nothing left to archive, and never reaches another column.
    #expect(!(model.selectedSession.map(model.canArchive) ?? false))
    #expect(await repository.session(id: other.id)?.taskStatus == .waiting)
  }

  @Test("After archiving the session on screen, its neighbour leaves the keyboard in the sidebar")
  func archivingKeepsTheKeyboardInTheSidebar() async {
    let archived = session("Archived", in: .done, updatedAt: 200)
    let next = session("Next", in: .done, updatedAt: 100)
    let other = session("Other", in: .done, updatedAt: 50)
    let (model, _, _) = makeWorkspace([archived, next, other])
    await model.load()
    model.setColumn(.done)
    model.select(archived.id)
    let requests = model.sidebarFocusRequest

    await model.requestArchive(archived.id)

    #expect(model.selectedSessionID == next.id)
    #expect(model.sidebarFocusRequest == requests + 1)
    #expect(!model.terminalClaimsKeyboardOnActivation)
    #expect(!model.composerClaimsKeyboardOnActivation)

    // Another session put on screen by the application — a new one, one followed — takes the
    // keyboard as it always has: only the neighbour leaves it in the sidebar.
    model.select(other.id, leavingDraft: false)
    #expect(model.terminalClaimsKeyboardOnActivation)
    model.select(next.id, leavingDraft: false)
    #expect(!model.terminalClaimsKeyboardOnActivation)

    // Going to a session by hand gives the keyboard back to the sessions shown.
    model.select(next.id)
    #expect(model.terminalClaimsKeyboardOnActivation)
  }

  @Test("⌃⌘A pressed twice before the first archive is done archives the session once")
  func archivingTwiceAtOnce() async {
    let subject = session("Subject", in: .done)
    let (model, _, repository) = makeWorkspace([subject])
    await model.load()

    async let first: Void = model.requestArchive(subject.id)
    async let second: Void = model.requestArchive(subject.id)
    _ = await (first, second)

    #expect(await repository.session(id: subject.id)?.taskStatus == .archived)
    #expect(model.archivingSessionIDs.isEmpty)
    #expect(model.refreshFailure == nil)
  }

  @Test("Archiving the selected session hands the selection to the next row")
  func archivingHandsOverTheSelection() async {
    let archived = session("Archived", in: .done, updatedAt: 200)
    let next = session("Next", in: .done, updatedAt: 100)
    let (model, _, _) = makeWorkspace([archived, next])
    await model.load()
    model.setColumn(.done)
    model.select(archived.id)

    await model.archive(archived.id)

    #expect(model.selectedSessionID == next.id)
  }

  @Test("An archived session opened from the foot of the sidebar stays on screen")
  func archivedSelectionSticks() async {
    let kept = session("Kept")
    var archived = session("Archived", in: .done)
    try? archived.archive(at: Date(timeIntervalSince1970: 500))
    let (model, _, _) = makeWorkspace([kept, archived])
    await model.load()

    model.showArchived(archived.id)
    await model.reload()

    #expect(model.selectedSessionID == archived.id)

    // Another column is somewhere else: the archived session gives way to its first row.
    model.setColumn(.doing)
    #expect(model.selectedSessionID == kept.id)
  }

  @Test("Unarchiving brings a session back to Done")
  func unarchivingGoesToDone() async {
    var archived = session("Archived", in: .done)
    try? archived.archive(at: Date(timeIntervalSince1970: 500))
    let (model, _, repository) = makeWorkspace([archived])
    await model.load()

    await model.setTaskStatus(.todo, for: archived.id)

    #expect(await repository.session(id: archived.id)?.taskStatus == .done)
  }

  // MARK: - Starting from To Do

  @Test("Moving a session that never ran In Progress starts its agent, and the column follows")
  func startingFromToDo() async throws {
    let path = folder()
    let planned = SessionDraft(
      name: "Planned", initialPrompt: "Split the check out.", providerID: "stub",
      workingDirectoryPath: path
    ).session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (model, launcher, repository) = makeWorkspace([planned])
    await model.load()
    await model.refreshResolutions()
    #expect(planned.taskStatus == .todo)
    model.setColumn(.todo)

    await model.setTaskStatus(.doing, for: planned.id)

    let stored = try #require(await repository.session(id: planned.id))
    #expect(stored.taskStatus == .doing)
    #expect(stored.status == .active)
    #expect(launcher.isRunning(planned.id))
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == planned.id)
  }

  // MARK: - Moving In Progress (#192)

  @Test(
    "A closed session moved In Progress from any column is shown there, selected, and restarted",
    arguments: [SessionTaskStatus.todo, .waiting, .done])
  func movingInProgressRestarts(from column: SessionTaskStatus) async throws {
    let path = folder()
    let other = session("Other", in: column, updatedAt: 300, path: path)
    let subject = session("Subject", in: column, updatedAt: 200, path: path)
    let (model, launcher, repository) = makeWorkspace([other, subject])
    await model.load()
    await model.refreshResolutions()
    model.setColumn(column)
    model.select(subject.id)

    await model.setTaskStatus(.doing, for: subject.id)

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.taskStatus == .doing)
    #expect(stored.status == .active)
    #expect(launcher.isRunning(subject.id))
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == subject.id)
    #expect(model.visibleSessions.map(\.id) == [subject.id])
  }

  @Test("A session moved In Progress from another row's selection is the one selected")
  func movingAnotherRowInProgressSelectsIt() async {
    let path = folder()
    let shown = session("Shown", in: .done, updatedAt: 300, path: path)
    let moved = session("Moved", in: .done, updatedAt: 200, path: path)
    let (model, _, _) = makeWorkspace([shown, moved])
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.done)
    model.select(shown.id)

    // A swipe on a row that is not the selected one.
    await model.setTaskStatus(.doing, for: moved.id)

    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == moved.id)
  }

  @Test("A session whose agent runs is moved In Progress and shown, and nothing is restarted")
  func movingARunningSessionRestartsNothing() async {
    let path = folder()
    let running = session("Running", in: .waiting, path: path, status: .active)
    let supervisor = WorkspaceSupervisor()
    let (model, _, repository) = makeWorkspace([running], supervisor: supervisor)
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.waiting)

    await model.setTaskStatus(.doing, for: running.id)

    #expect(await repository.session(id: running.id)?.taskStatus == .doing)
    #expect(await supervisor.startCount == 0)
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == running.id)
  }

  @Test("A restart that fails leaves the session In Progress, selected, and says why")
  func failedRestartKeepsTheMove() async {
    let path = folder()
    let subject = session("Subject", in: .done, path: path)
    let (model, launcher, repository) = makeWorkspace(
      [subject], supervisor: WorkspaceSupervisor(failure: .resourceLimitReached(code: 35)))
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.done)

    await model.setTaskStatus(.doing, for: subject.id)

    #expect(await repository.session(id: subject.id)?.taskStatus == .doing)
    #expect(!launcher.isRunning(subject.id))
    #expect(model.restartFailure != nil)
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == subject.id)
  }

  @Test("A restart that needs its summary read asks for it, and the session is In Progress")
  func summaryToReadKeepsTheMove() async {
    let path = folder()
    let subject = session("Subject", in: .done, path: path, resumable: false)
    let (model, launcher, repository) = makeWorkspace([subject])
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.done)

    await model.setTaskStatus(.doing, for: subject.id)

    #expect(model.pendingRestart?.sessionID == subject.id)
    #expect(!launcher.isRunning(subject.id))
    #expect(await repository.session(id: subject.id)?.taskStatus == .doing)
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == subject.id)
  }

  @Test("A search that hides the session moved In Progress is left as it is")
  func movingInProgressKeepsTheSearch() async {
    let path = folder()
    let subject = session("Webhook", in: .done, path: path)
    let (model, _, _) = makeWorkspace([subject])
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.done)
    model.select(subject.id)
    // Typed after the session was chosen: it hides the session, which stays on screen.
    model.setSearchText("signature")

    await model.setTaskStatus(.doing, for: subject.id)

    #expect(model.filter.searchText == "signature")
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == subject.id)
  }

  @Test("An archived session only comes back through Unarchive, never straight In Progress")
  func archivedIsNotMovedInProgress() async {
    let path = folder()
    var archived = session("Archived", in: .done, path: path)
    try? archived.archive(at: Date(timeIntervalSince1970: 500))
    let (model, launcher, repository) = makeWorkspace([archived])
    await model.load()

    #expect(model.nextTaskStatuses(of: archived).isEmpty)
    await model.setTaskStatus(.doing, for: archived.id)

    #expect(await repository.session(id: archived.id)?.taskStatus == .done)
    #expect(!launcher.isRunning(archived.id))
  }

  @Test("A session moved elsewhere starts nothing", arguments: [SessionTaskStatus.waiting, .done])
  func movingStartsNothing(to status: SessionTaskStatus) async {
    let path = folder()
    let planned = SessionDraft(
      name: "Planned", initialPrompt: "Later.", providerID: "stub", workingDirectoryPath: path
    ).session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (model, launcher, repository) = makeWorkspace([planned])
    await model.load()
    model.setColumn(.todo)

    await model.setTaskStatus(status, for: planned.id)

    #expect(await repository.session(id: planned.id)?.taskStatus == status)
    #expect(!launcher.isRunning(planned.id))
    #expect(model.filter.column == .todo)
  }

  @Test("Restarting a finished session puts it back In Progress, and the column follows")
  func restartingReopensTheTask() async {
    let path = folder()
    let finished = session("Finished", in: .done, path: path)
    let (model, _, repository) = makeWorkspace([finished])
    await model.load()
    await model.refreshResolutions()
    model.setColumn(.done)

    await model.restart(finished.id)

    #expect(await repository.session(id: finished.id)?.taskStatus == .doing)
    #expect(model.filter.column == .doing)
    #expect(model.selectedSessionID == finished.id)
  }

  @Test("Restarting a waiting session leaves it waiting")
  func restartingKeepsWaiting() async {
    let path = folder()
    let waiting = session("Waiting", in: .waiting, path: path)
    let (model, _, repository) = makeWorkspace([waiting])
    await model.load()
    await model.refreshResolutions()

    await model.restart(waiting.id)

    #expect(await repository.session(id: waiting.id)?.status == .active)
    #expect(await repository.session(id: waiting.id)?.taskStatus == .waiting)
  }

  @Test("A session added to To Do is not launched, and the column shows it")
  func addingToToDo() async throws {
    let path = folder()
    let planned = SessionDraft(
      name: "Planned", initialPrompt: "Later.", providerID: "stub", workingDirectoryPath: path
    ).session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (model, launcher, repository) = makeWorkspace([])
    await model.load()
    await repository.save(planned)
    let plan = AgentLaunchPlan(
      providerID: AgentProviderID("stub"), executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: path, promptDelivery: .none)

    await model.complete(SessionCreation(session: planned, plan: plan), launching: false)

    #expect(!launcher.isRunning(planned.id))
    #expect(model.filter.column == .todo)
    #expect(model.visibleSessions.map(\.id) == [planned.id])
    #expect(model.selectedSessionID == planned.id)
  }

  // MARK: - Columns

  @Test("⌃⌘→ and ⌃⌘← walk the four columns and stop at both ends")
  func columnShortcuts() async {
    let (model, _, _) = makeWorkspace([session("Any")])
    await model.load()
    model.setColumn(.todo)

    model.showPreviousColumn()
    #expect(model.filter.column == .todo)
    for expected in [SessionTaskStatus.doing, .waiting, .done, .done] {
      model.showNextColumn()
      #expect(model.filter.column == expected)
    }
  }

  @Test("A tab counts what clicking it will show, search included")
  func tabsCountWhatTheyShow() async {
    let (model, _, _) = makeWorkspace([
      session("Webhook retries", in: .todo), session("Docs", in: .todo),
      session("Webhook signature", in: .done),
    ])
    await model.load()

    #expect(model.summary(of: .todo).count == 2)
    #expect(model.summary(of: .doing).count == 0)

    model.setSearchText("webhook")
    #expect(model.summary(of: .todo).count == 1)
    #expect(model.summary(of: .done).count == 1)
  }
}

@Suite("The arithmetic of a swipe")
struct SessionSwipeTests {
  private func swipe(
    leading: [SessionTaskStatus] = [.todo], trailing: [SessionTaskStatus] = [.waiting, .done],
    width: CGFloat = 280, translation: CGFloat
  ) -> SessionSwipe {
    SessionSwipe(
      sessionID: SessionID(), leading: leading, trailing: trailing, availableWidth: width,
      translation: translation)
  }

  @Test("The row follows the gesture up to the buttons and their gap, then gives way")
  func elasticPastTheButtons() {
    #expect(swipe(translation: 50).offset == 50)
    #expect(swipe(translation: 84).offset == 84)
    #expect(swipe(translation: 184).offset == 84 + 100 * 0.3)
    #expect(swipe(translation: -160).offset == -160)
  }

  @Test("A side opens on its buttons and a gap between them and the row")
  func gapBeforeTheButtons() {
    let open = swipe(translation: 0)
    #expect(open.leadingButtonsWidth == 76)
    #expect(open.leadingWidth == 76 + SessionSwipe.gap)
    #expect(open.trailingButtonsWidth == 152)
    #expect(open.trailingWidth == 152 + SessionSwipe.gap)
    #expect(swipe(leading: [], translation: 0).leadingWidth == 0)
  }

  @Test("The gap stays the same while the buttons are uncovered")
  func buttonsKeepTheirDistance() {
    #expect(swipe(translation: 4).revealedButtonsWidth == 0)
    #expect(swipe(translation: 50).revealedButtonsWidth == 50 - SessionSwipe.gap)
    #expect(swipe(translation: 84).revealedButtonsWidth == 76)
    #expect(swipe(translation: -160).revealedButtonsWidth == 152)
  }

  @Test("A side with nothing to offer barely moves")
  func bareSide() {
    let atTheStart = swipe(leading: [], translation: 400)
    #expect(atTheStart.offset == SessionSwipe.bareSideLimit)
    #expect(atTheStart.settledTranslation == 0)
  }

  @Test("Let go past 40 % of the buttons and their gap, they stay open; short of it, they close")
  func settling() {
    #expect(swipe(translation: 34).settledTranslation == 84)
    #expect(swipe(translation: 33).settledTranslation == 0)
    #expect(swipe(translation: -64).settledTranslation == -160)
    #expect(swipe(translation: -63).settledTranslation == 0)
  }

  @Test("Opening from the keyboard uncovers the gap too")
  func openingAtOnce() {
    var closed = swipe(translation: 0)
    closed.open(towardsNext: true)
    #expect(closed.translation == -160)
    closed.open(towardsNext: false)
    #expect(closed.translation == 84)
  }

  @Test("The buttons and their gap never take the whole row")
  func widthIsCapped() {
    let many = swipe(trailing: [.doing, .waiting, .done], width: 200, translation: -500)
    #expect(many.trailingWidth == 200 - SessionSwipe.reservedWidth)
    #expect(many.trailingButtonsWidth == 200 - SessionSwipe.reservedWidth - SessionSwipe.gap)
  }

  @Test("Each side reveals its own statuses")
  func revealedStatuses() {
    #expect(swipe(translation: 20).revealedStatuses == [.todo])
    #expect(swipe(translation: -20).revealedStatuses == [.waiting, .done])
    #expect(swipe(translation: 0).revealedStatuses.isEmpty)
  }
}
