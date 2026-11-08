import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The cards of a dialog guessed at a start, as a restoration resumes sessions.
@MainActor
@Suite("Dialogs of a start in the palette of requests", .timeLimit(.minutes(1)))
struct StartupDialogRequestsTests {
  private func model(coordinator: WorkSession? = nil) async -> (AppModel, WorkSession) {
    var subject = WorkSession(
      name: "skill deploy", initialPrompt: "Deploy.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000))
    if let coordinator { subject.coordination = .child(of: coordinator.id) }
    let repository = WorkspaceRepository(sessions: [subject] + [coordinator].compactMap { $0 })
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.reload()
    return (model, subject)
  }

  private func waiting(_ id: SessionID, on kind: AgentTerminalPrompt.Kind) -> AgentActivityState {
    var state = AgentActivityState(source: .inferred)
    state.requests = [
      AgentRequest(
        id: AgentRequestID(sessionID: id, key: "startup"), receivedAt: Date(), kind: .approval,
        content: .inTerminal(AgentTerminalPrompt(kind: kind, message: nil)),
        reference: AgentToolReference(tool: nil), isShown: true)
    ]
    state.activity = .awaitingUser(.approval)
    return state
  }

  @Test("A guess shows once its screen was read: a prompt at rest takes it away unseen")
  func guessShownOnceRead() async {
    let (model, subject) = await model()
    model.activityCells.set(waiting(subject.id, on: .startup), for: subject.id)
    #expect(model.pendingRequests.isEmpty)
    model.readStartupGuesses.insert(AgentRequestID(sessionID: subject.id, key: "startup"))
    #expect(model.pendingRequests.count == 1)
  }

  @Test("A guess no card shows waits on no one, in the sidebar or on the phone (#474)")
  func guessNotWaitingUntilShown() async {
    let (model, subject) = await model()
    model.activityCells.set(waiting(subject.id, on: .startup), for: subject.id)
    #expect(model.shownActivity(for: subject.id)?.activity == .idle)
    #expect(model.shownActivity(for: subject.id)?.requests.isEmpty == true)
    #expect(!model.statusPresentation(for: subject).needsAttention)
    model.readStartupGuesses.insert(AgentRequestID(sessionID: subject.id, key: "startup"))
    #expect(model.shownActivity(for: subject.id)?.activity == .awaitingUser(.approval))
    #expect(model.shownActivity(for: subject.id)?.requests.count == 1)
  }

  @Test("A guess no card shows is not a child that needs its coordinator's user (#474)")
  func guessNotTellingCoordinator() async {
    var coordinator = WorkSession(
      name: "lead", initialPrompt: "Lead.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "lead"))
    coordinator.coordination = .coordinator
    let (model, subject) = await model(coordinator: coordinator)
    let guess = waiting(subject.id, on: .startup)
    model.activityCells.set(guess, for: subject.id)
    #expect(model.summary(ofCoordinator: coordinator.id).needingUser == 0)
    #expect(!AppModel.waitsForUser(guess))
    #expect(AppModel.waitsForUser(waiting(subject.id, on: .trust)))
    model.readStartupGuesses.insert(AgentRequestID(sessionID: subject.id, key: "startup"))
    #expect(model.summary(ofCoordinator: coordinator.id).needingUser == 1)
  }

  @Test("During a restoration, the dialogs of the starts wait for its end, to come together")
  func heldDuringRestoration() async {
    let (model, subject) = await model()
    model.restoration = AppModel.Restoration(
      total: 3, completed: 1, currentSessionID: nil, currentName: nil)
    model.activityCells.set(waiting(subject.id, on: .trust), for: subject.id)
    #expect(model.pendingRequests.isEmpty)
    await model.finishRestore(with: [])
    #expect(model.pendingRequests.count == 1)
  }
}
