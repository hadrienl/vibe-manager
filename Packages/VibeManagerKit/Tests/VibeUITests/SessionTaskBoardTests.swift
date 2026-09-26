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
    path: String = "/workspace"
  ) -> WorkSession {
    let date = Date(timeIntervalSince1970: seconds)
    return WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      // A conversation to resume, so that a restart starts without a summary to confirm.
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept-identifier"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: date,
      closedAt: date,
      startedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)],
      taskStatus: column
    )
  }

  private func makeWorkspace(_ sessions: [WorkSession])
    -> (AppModel, SessionLauncher, WorkspaceRepository)
  {
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
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

  @Test("Archive from the swipe asks first, as the command does")
  func archivingAsks() async {
    let subject = session("Subject", in: .done)
    let (model, _, repository) = makeWorkspace([subject])
    await model.load()

    await model.setTaskStatus(.archived, for: subject.id)

    #expect(model.pendingArchive?.id == subject.id)
    #expect(await repository.session(id: subject.id)?.taskStatus == .done)

    await model.archive(subject.id)
    #expect(await repository.session(id: subject.id)?.taskStatus == .archived)
    #expect(model.archivedSessions.map(\.id) == [subject.id])
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

  @Test("Moving a session that never ran In Progress starts its agent, and the column stays")
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
    #expect(model.filter.column == .todo)
  }

  @Test("A session moved elsewhere starts nothing")
  func movingStartsNothing() async {
    let path = folder()
    let planned = SessionDraft(
      name: "Planned", initialPrompt: "Later.", providerID: "stub", workingDirectoryPath: path
    ).session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (model, launcher, repository) = makeWorkspace([planned])
    await model.load()

    await model.setTaskStatus(.waiting, for: planned.id)

    #expect(await repository.session(id: planned.id)?.taskStatus == .waiting)
    #expect(!launcher.isRunning(planned.id))
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

  @Test("The columns follow the gesture up to the buttons, then give way")
  func elasticPastTheButtons() {
    #expect(swipe(translation: 50).offset == 50)
    #expect(swipe(translation: 76).offset == 76)
    #expect(swipe(translation: 176).offset == 76 + 100 * 0.3)
    #expect(swipe(translation: -152).offset == -152)
  }

  @Test("A side with nothing to offer barely moves")
  func bareSide() {
    let atTheStart = swipe(leading: [], translation: 400)
    #expect(atTheStart.offset == SessionSwipe.bareSideLimit)
    #expect(atTheStart.settledTranslation == 0)
  }

  @Test("Let go past 40 % of the buttons, they stay open; short of it, they close")
  func settling() {
    #expect(swipe(translation: 31).settledTranslation == 76)
    #expect(swipe(translation: 30).settledTranslation == 0)
    #expect(swipe(translation: -61).settledTranslation == -152)
    #expect(swipe(translation: -60).settledTranslation == 0)
  }

  @Test("The buttons never take the whole row")
  func widthIsCapped() {
    let many = swipe(trailing: [.doing, .waiting, .done], width: 200, translation: -500)
    #expect(many.trailingWidth == 200 - SessionSwipe.reservedWidth)
  }

  @Test("Each side reveals its own statuses")
  func revealedStatuses() {
    #expect(swipe(translation: 20).revealedStatuses == [.todo])
    #expect(swipe(translation: -20).revealedStatuses == [.waiting, .done])
    #expect(swipe(translation: 0).revealedStatuses.isEmpty)
  }
}
