import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The first launch's tour, in the workspace", .timeLimit(.minutes(2)))
struct OnboardingWorkspaceTests {
  private let folder = FileManager.default.temporaryDirectory.path

  private func makeWorkspace(
    _ sessions: [WorkSession] = [],
    tour: OnboardingTour = .notStarted,
    suppressed: Bool = false,
    permissions: PermissionsModel? = nil
  ) -> (AppModel, InMemoryOnboardingPreferences, WorkspaceSupervisor) {
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let supervisor = WorkspaceSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, permissions: permissions)
    let preferences = InMemoryOnboardingPreferences(tour: tour, isTourSuppressed: suppressed)
    model.onboarding = OnboardingModel(preferences: preferences)
    return (model, preferences, supervisor)
  }

  private func existing() -> WorkSession {
    SessionDraft(name: "Existing", providerID: "stub", workingDirectoryPath: folder).session()
  }

  /// Opens the draft and fills it in, as the user would along the bubbles.
  private func fillDraft(in model: AppModel) throws {
    model.beginNewSession()
    let draft = try #require(model.newSessionModel)
    draft.draft = SessionDraft(
      name: "First", initialPrompt: "Hello", providerID: "stub", workingDirectoryPath: folder)
  }

  @Test("A first launch shows the first bubble on New Session, in the empty window")
  func firstLaunch() async {
    let (model, preferences, _) = makeWorkspace()
    await model.load()

    #expect(model.onboarding.step == .newSession)
    #expect(preferences.tour == .step(.newSession, session: nil))
    #expect(model.tourStep(on: .emptyStateNewSession) == .newSession)
    #expect(model.tourStep(on: .draftName) == nil)
  }

  @Test("Walked to the end: draft, To Do, In Progress starts the agent, and done")
  func walkedThrough() async throws {
    let (model, preferences, supervisor) = makeWorkspace()
    await model.load()

    try fillDraft(in: model)
    #expect(model.onboarding.step == .name)
    #expect(model.tourStep(on: .draftName) == .name)
    #expect(model.tourStep(on: .emptyStateNewSession) == nil)
    model.onboarding.send(.nameCommitted)
    model.onboarding.send(.folderChosen)
    model.onboarding.send(.promptTyped)
    #expect(model.tourStep(on: .draftComposer) == .prompt)

    model.submitNewSession(launching: false)
    await waitUntil("the session is made") { model.onboarding.step == .statuses }
    let id = try #require(model.onboarding.sessionID)
    await waitUntil("the creation is over") { model.sessionInCreation == nil }
    #expect(model.sessions.first { $0.id == id }?.taskStatus == .todo)
    #expect(model.tourStep(on: .sessionRow(id)) == .statuses)
    #expect(model.tourStep(on: .sessionRow(SessionID())) == nil)
    // Waiting in To Do: the bubble asks for the move, and offers nothing else.
    #expect(model.tourBubble(for: .statuses).advance == nil)
    #expect(await supervisor.startCount == 0)

    await model.setTaskStatus(.doing, for: id)

    #expect(model.onboarding.step == .finale)
    #expect(model.tourStep(on: .sessionRow(id)) == .finale)
    await waitUntil("the agent starts") { await supervisor.startCount == 1 }
    model.onboarding.send(.next)
    #expect(model.onboarding.tour == .finished)
    #expect(preferences.tour == .finished)
  }

  @Test("A session launched at once skips the invitation to move it")
  func launchedAtOnce() async throws {
    let (model, _, _) = makeWorkspace()
    await model.load()
    try fillDraft(in: model)

    model.submitNewSession(launching: true)
    await waitUntil("the session is made") { model.onboarding.step == .statuses }
    await waitUntil("the creation is over") { model.sessionInCreation == nil }

    #expect(model.tourBubble(for: .statuses).advance == .next)
  }

  @Test("Started some other way — Start Session — the session still ends the tour")
  func startedElsewhere() async throws {
    let (model, _, _) = makeWorkspace()
    await model.load()
    try fillDraft(in: model)
    model.submitNewSession(launching: false)
    await waitUntil("the creation is over") {
      model.onboarding.step == .statuses && model.sessionInCreation == nil
    }
    let id = try #require(model.onboarding.sessionID)

    // What the launcher writes when it starts a session of To Do.
    _ = try await ChangeTaskStatus(repository: model.repository).beginWork(id: id)
    await model.reload()

    #expect(model.onboarding.step == .finale)
  }

  @Test("A draft opened before the list was read is where the tour starts")
  func draftBeforeLoad() async {
    let (model, _, _) = makeWorkspace()
    model.beginNewSession()
    await model.load()

    #expect(model.onboarding.step == .name)
    #expect(model.tourStep(on: .draftName) == .name)
  }

  @Test("A discarded draft sends the tour back to New Session")
  func discardedDraft() async throws {
    let (model, _, _) = makeWorkspace()
    await model.load()
    try fillDraft(in: model)
    #expect(model.onboarding.step == .name)

    model.discardNewSessionDraft(undoManager: nil)

    #expect(model.onboarding.step == .newSession)
  }

  @Test("An installation with sessions never sees the tour, and remembers it")
  func existingUser() async {
    let (model, preferences, _) = makeWorkspace([existing()])
    await model.load()

    #expect(model.onboarding.tour == .finished)
    #expect(preferences.tour == .finished)
    #expect(model.tourStep(on: .toolbarNewSession) == nil)
  }

  @Test("Relaunched midway: on the row it was on, or at New Session when the session is gone")
  func resumed() async {
    let session = existing()
    let (kept, _, _) = makeWorkspace([session], tour: .step(.statuses, session: session.id))
    await kept.load()
    #expect(kept.onboarding.tour == .step(.statuses, session: session.id))

    let (lost, preferences, _) = makeWorkspace(
      [session], tour: .step(.statuses, session: SessionID()))
    await lost.load()
    #expect(lost.onboarding.tour == .step(.newSession, session: nil))
    #expect(preferences.tour == .step(.newSession, session: nil))
    // Sessions on screen: the first bubble points at the toolbar's New Session.
    #expect(lost.tourStep(on: .toolbarNewSession) == .newSession)
  }

  @Test("Show Tutorial Again starts over, from the draft when one is open")
  func replay() async throws {
    let (model, _, _) = makeWorkspace([existing()])
    var shownWindow = 0
    model.showWorkspaceWindow = { shownWindow += 1 }
    await model.load()
    #expect(model.onboarding.tour == .finished)

    model.replayTutorial()
    #expect(model.onboarding.step == .newSession)
    #expect(shownWindow == 1)

    model.beginNewSession()
    model.onboarding.send(.skip)
    model.replayTutorial()
    #expect(model.onboarding.step == .name)
  }

  @Test("No bubble over Open Quickly")
  func heldBackByOpenQuickly() async {
    let (model, _, _) = makeWorkspace()
    await model.load()
    model.presentQuickOpen()

    #expect(model.tourStep(on: .emptyStateNewSession) == nil)
  }

  @Test("No bubble while the Full Disk Access step is up; the tour waits for it")
  func heldBackByFullDiskAccess() async {
    let permissions = PermissionsModel(
      gate: FullDiskAccessGate(probe: NotGranted(), preferences: NoAnswer(), runner: nil),
      control: nil, openURL: { _ in })
    let (model, _, _) = makeWorkspace(permissions: permissions)
    await model.load()
    #expect(permissions.isPresentingStep)
    #expect(model.onboarding.step == .newSession)
    #expect(model.tourStep(on: .emptyStateNewSession) == nil)

    await permissions.skipStep()

    #expect(model.tourStep(on: .emptyStateNewSession) == .newSession)
  }

  @Test("Suppressed, the tour neither shows nor writes anything")
  func suppressed() async {
    let (model, preferences, _) = makeWorkspace(suppressed: true)
    await model.load()

    #expect(model.onboarding.tour == .finished)
    #expect(preferences.tour == .notStarted)
  }
}

@Suite("Where a bubble of the tour goes")
struct TourBubblePlacementTests {
  private let bubble = CGSize(width: 290, height: 120)
  private let container = CGSize(width: 800, height: 600)

  @Test("Under its target when there is room, its arrow on the target's middle")
  func below() {
    let target = CGRect(x: 100, y: 50, width: 200, height: 30)
    let placement = TourBubblePlacement(bubble: bubble, target: target, container: container)

    #expect(placement.isBelow)
    #expect(placement.origin.y == target.maxY + TourBubblePlacement.arrowLength)
    #expect(placement.origin.x + placement.arrowX == target.midX)
  }

  @Test("Over its target at the foot of the container")
  func above() {
    let target = CGRect(x: 100, y: 500, width: 600, height: 80)
    let placement = TourBubblePlacement(bubble: bubble, target: target, container: container)

    #expect(!placement.isBelow)
    #expect(
      placement.origin.y + bubble.height == target.minY - TourBubblePlacement.arrowLength)
  }

  @Test("Never out of the container, its arrow still on the bubble")
  func clamped() {
    let target = CGRect(x: 760, y: 50, width: 30, height: 20)
    let placement = TourBubblePlacement(bubble: bubble, target: target, container: container)

    #expect(placement.origin.x + bubble.width <= container.width - TourBubblePlacement.margin)
    #expect(placement.arrowX <= bubble.width - TourBubblePlacement.arrowInset)
  }
}

private struct NotGranted: FullDiskAccessProbe {
  func status() async -> FullDiskAccessStatus { .notGranted }
}

private actor NoAnswer: PermissionPreferences {
  private var answer: CodeIdentityFingerprint?

  func isFullDiskAccessStepSuppressed() -> Bool { false }
  func fullDiskAccessStepAnswer() -> CodeIdentityFingerprint? { answer }
  func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) { answer = identity }
}
