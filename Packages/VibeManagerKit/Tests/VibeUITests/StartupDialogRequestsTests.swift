import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The cards of a dialog guessed at a start, as a restoration resumes sessions.
@MainActor
@Suite("Dialogs of a start in the palette of requests", .timeLimit(.minutes(1)))
struct StartupDialogRequestsTests {
  private func model() async -> (AppModel, WorkSession) {
    let subject = WorkSession(
      name: "skill deploy", initialPrompt: "Deploy.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let repository = WorkspaceRepository(sessions: [subject])
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
