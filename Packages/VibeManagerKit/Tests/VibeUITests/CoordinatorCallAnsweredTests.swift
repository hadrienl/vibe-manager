import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// #417: a coordinator that called the user is answered once they write to it, from wherever they
/// write — not by what the application types into it.
@MainActor
@Suite("A coordinator's call, answered by writing to it (#417)", .timeLimit(.minutes(2)))
struct CoordinatorCallAnsweredTests {
  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-call-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func session(_ name: String, coordination: SessionCoordination? = nil) -> WorkSession {
    WorkSession(
      name: name,
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: folder())],
      coordination: coordination)
  }

  /// A coordinator and another session, both running, the coordinator calling the user.
  private func calling() async throws -> (AppModel, SessionLauncher, WorkSession, WorkSession) {
    let coordinator = session("Bugs en vrac", coordination: .coordinator)
    let other = session("Other")
    let repository = WorkspaceRepository(sessions: [coordinator, other])
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.refreshAgents()
    for subject in [coordinator, other] {
      let path = try #require(RestartSession.workingDirectoryPath(of: subject))
      let plan = try await WorkspaceProvider().launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: path))
      await launcher.launch(session: subject, plan: plan)
    }
    await model.reload()
    model.coordination.calls[coordinator.id] = "Approve the plan."
    return (model, launcher, coordinator, other)
  }

  @Test("Typing to the coordinator, out of sight, answers its call")
  func typingAnswers() async throws {
    let (model, _, coordinator, _) = try await calling()
    #expect(!model.isOnScreen(coordinator.id))
    // The terminal's keys and the composer's message — the phone's too — both go through here.
    try #require(model.pane(for: coordinator.id)).noteKeyboardInput()
    #expect(!model.isCallingUser(coordinator.id))
  }

  @Test("Typing to another session leaves the call")
  func otherSessionLeaves() async throws {
    let (model, _, coordinator, other) = try await calling()
    try #require(model.pane(for: other.id)).noteKeyboardInput()
    #expect(model.isCallingUser(coordinator.id))
  }

  @Test("A message the application types into the coordinator leaves the call")
  func applicationTypingLeaves() async throws {
    let (model, launcher, coordinator, _) = try await calling()
    let outcome = await launcher.typeMessage("A child finished.", into: coordinator.id) {
      .atRest
    }
    #expect(outcome == .submitted)
    #expect(model.isCallingUser(coordinator.id))
  }
}
