import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// #409: a session restarted onto its agent's updated CLI, its conversation resumed.
@MainActor
@Suite("Restarting a session onto its updated agent", .timeLimit(.minutes(2)))
struct AgentUpdateRestartTests {
  private let update = AgentUpdate(runningVersion: "2.1.299", installedVersion: "2.1.303")

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-update-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func session(path: String, resumeIdentifier: String? = "kept-identifier") -> WorkSession
  {
    WorkSession(
      name: "Audit deps",
      initialPrompt: "Audit the dependencies.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: resumeIdentifier),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: path)]
    )
  }

  /// A workspace whose session's agent runs.
  private func running(
    _ subject: WorkSession, automatic: Set<AgentProviderID> = []
  ) async throws -> (AppModel, SessionLauncher, WorkspaceSupervisor) {
    let supervisor = WorkspaceSupervisor()
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      agentUpdatePreferences: InMemoryAgentUpdatePreferences(automatic: automatic))
    await model.refreshAgents()
    let path = try #require(RestartSession.workingDirectoryPath(of: subject))
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()
    return (model, launcher, supervisor)
  }

  @Test("The separator names the update between the two builds")
  func separatorNamesTheUpdate() {
    let line = SessionLauncher.updateSeparator(
      for: update, at: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(line.contains("Update"))
    #expect(line.contains("2.1.299 → 2.1.303"))
    #expect(line.contains("resumed conversation"))
  }

  @Test("Asked while the agent may be busy, the restart waits, and can be cancelled")
  func restartWaitsUntilNothingWouldBeLost() async throws {
    let subject = session(path: folder())
    let (model, _, supervisor) = try await running(subject)

    model.noteAgentUpdates([subject.id: update])
    let notice = try #require(model.agentUpdateNotice(for: subject.id))
    #expect(notice.installedVersion == "2.1.303")
    #expect(!notice.isPending)

    // No activity is followed in this workspace: nothing says the agent is done.
    model.restartForUpdate(subject.id)
    #expect(model.pendingUpdateRestarts == [subject.id])
    await model.restartPendingUpdates()
    #expect(await supervisor.startCount == 1)

    model.cancelUpdateRestart(subject.id)
    #expect(model.pendingUpdateRestarts.isEmpty)
    #expect(model.agentUpdateNotice(for: subject.id)?.isPending == false)
  }

  @Test("The restart stops the agent and resumes its conversation under an update separator")
  func restartResumesTheConversation() async throws {
    let subject = session(path: folder())
    let (model, launcher, supervisor) = try await running(subject)
    model.noteAgentUpdates([subject.id: update])
    _ = launcher.pane(for: subject.id)?.takePendingNotice()

    await model.restartInPlace(subject.id, update: update)

    #expect(await supervisor.startCount == 2)
    #expect(await supervisor.lastSpec?.arguments == ["--resume", "kept-identifier"])
    #expect(model.agentUpdates.isEmpty)
    #expect(model.agentUpdateNotice(for: subject.id) == nil)
    let line = String(
      decoding: launcher.pane(for: subject.id)?.takePendingNotice() ?? [], as: UTF8.self)
    #expect(line.contains("2.1.299 → 2.1.303"))
  }

  @Test("A session whose conversation could not be resumed is offered nothing")
  func noResumeNoOffer() async throws {
    let subject = session(path: folder(), resumeIdentifier: nil)
    let (model, _, _) = try await running(subject)

    model.noteAgentUpdates([subject.id: update])

    #expect(model.agentUpdateNotice(for: subject.id) == nil)
    #expect(!model.canRestartInPlace(subject.id))
  }

  @Test("The agent's setting queues its sessions, but not one the user cancelled")
  func settingQueuesSessions() async throws {
    let subject = session(path: folder())
    let (model, _, _) = try await running(subject, automatic: [AgentProviderID("stub")])

    model.noteAgentUpdates([subject.id: update])
    #expect(model.pendingUpdateRestarts == [subject.id])

    model.cancelUpdateRestart(subject.id)
    model.noteAgentUpdates([subject.id: update])
    #expect(model.pendingUpdateRestarts.isEmpty)

    // A later update is another question.
    let next = AgentUpdate(runningVersion: "2.1.299", installedVersion: "2.1.305")
    model.noteAgentUpdates([subject.id: next])
    #expect(model.pendingUpdateRestarts == [subject.id])
  }
}
