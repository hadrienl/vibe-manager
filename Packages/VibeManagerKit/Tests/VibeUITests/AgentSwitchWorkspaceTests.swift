import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Switching the agent of a session from the workspace")
struct AgentSwitchWorkspaceTests {
  // MARK: - Fixtures

  private static let stub = WorkspaceProvider(
    catalog: [
      AgentModel(id: "fast", displayName: "Fast"), AgentModel(id: "deep", displayName: "Deep"),
    ])
  private static let other = WorkspaceProvider(
    id: "other", name: "Other Agent", catalog: [AgentModel(id: "o1", displayName: "O1")])

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-switch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func session(
    path: String,
    resumeIdentifier: String? = "kept-identifier"
  ) -> WorkSession {
    WorkSession(
      name: "Audit deps",
      initialPrompt: "Audit the dependencies.",
      agent: SessionAgentConfiguration(
        providerID: "stub", modelID: "fast", resumeIdentifier: resumeIdentifier),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: path)],
      notes: "Keep lodash."
    )
  }

  private func makeWorkspace(
    session: WorkSession,
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor()
  ) async -> (AppModel, SessionLauncher, WorkspaceSupervisor, WorkspaceRepository) {
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      viewportTimeout: .zero
    )
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.reload()
    return (model, launcher, supervisor, repository)
  }

  /// Opens the sheet and waits for it to have listed the agents, as the user would.
  private func openSheet(_ model: AppModel, for id: SessionID) async throws -> AgentSwitchModel {
    model.beginAgentSwitch(id)
    let sheet = try #require(model.pendingSwitch)
    await sheet.load()
    return sheet
  }

  // MARK: - The sheet

  @Test("The sheet opens on the current agent, and offers nothing until something changes")
  func sheetStartsOnTheCurrentAgent() async throws {
    let subject = session(path: folder())
    let (model, _, _, _) = await makeWorkspace(session: subject)

    let sheet = try await openSheet(model, for: subject.id)

    #expect(sheet.providerID == "stub")
    #expect(sheet.modelID == "fast")
    #expect(!sheet.canSwitch)
    #expect(sheet.confirmTitle == "Switch")
    #expect(sheet.stopWarning == nil)
    #expect(!model.canRestart(subject))
  }

  @Test("Another model of the same agent keeps the conversation, and says so")
  func sameAgentKeepsTheConversation() async throws {
    let subject = session(path: folder())
    let (model, _, _, _) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)

    sheet.select(model: "deep")

    #expect(sheet.handover == .resumesConversation)
    #expect(sheet.continuityNotice.contains("conversation continues with Deep"))
    #expect(sheet.canSwitch)
  }

  @Test("A conversation the agent dropped last time is not retried unless asked")
  func failedResumeIsOnlyRetriedOnRequest() async throws {
    let subject = session(path: folder())
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let sheet = AgentSwitchModel(
      session: subject,
      stopsRunningAgent: false,
      resumeFailedBefore: true,
      registry: registry,
      planner: PlanAgentSwitch(
        repository: WorkspaceRepository(sessions: [subject]), agents: registry),
      context: { session, names in SessionBriefInput(session: session, agentNames: names) }
    )
    await sheet.load()

    sheet.select(model: "deep")
    #expect(sheet.offersResumeRetry)
    #expect(sheet.skipsResume)
    #expect(sheet.handover == .summary)
    #expect(sheet.expectedModeKind == .handover)
    #expect(sheet.continuityNotice.contains("stopped as soon as this conversation was resumed"))

    sheet.retriesFailedResume = true
    #expect(!sheet.skipsResume)
    #expect(sheet.handover == .resumesConversation)
    #expect(sheet.expectedModeKind == .resumeWithModel)

    // Another agent resumes nothing, so there is nothing to ask.
    await sheet.select(agent: "other")
    #expect(!sheet.offersResumeRetry)
  }

  @Test("Another agent gets a summary, and the user's edits survive a change of model")
  func anotherAgentGetsAnEditableSummary() async throws {
    let subject = session(path: folder())
    let (model, _, _, _) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)

    await sheet.select(agent: "other")

    #expect(sheet.handover == .summary)
    #expect(sheet.modelID == nil)
    #expect(sheet.summaryText.contains("Stub Agent · fast"))
    #expect(sheet.continuityNotice.contains("will not see Stub Agent's conversation"))

    sheet.summaryText = "My own words."
    sheet.select(model: "o1")
    #expect(sheet.summaryText == "My own words.")
    #expect(sheet.isSummaryEdited)

    sheet.regenerateSummary()
    #expect(sheet.summaryText.contains("Agents so far"))
    #expect(!sheet.isSummaryEdited)
  }

  @Test("A summary over the limit cannot be sent")
  func overlongSummaryDisablesTheSwitch() async throws {
    let subject = session(path: folder())
    let (model, _, _, _) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")

    sheet.summaryText = String(repeating: "x", count: AgentPromptLimits.argumentByteLimit + 10)

    #expect(sheet.summaryOverflow == 10)
    #expect(!sheet.canSwitch)
  }

  // MARK: - The switch

  @Test("A closed session is switched, recorded and started on the new agent")
  func closedSessionIsSwitched() async throws {
    let subject = session(path: folder())
    let (model, launcher, supervisor, repository) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    sheet.select(model: "o1")

    await model.confirmAgentSwitch()

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.status == .active)
    #expect(stored.agent == SessionAgentConfiguration(providerID: "other", modelID: "o1"))
    #expect(stored.agentHistory.count == 1)
    #expect(stored.agentHistory.first?.previous == subject.agent)
    #expect(stored.notes == subject.notes)
    #expect(await supervisor.startCount == 1)
    #expect(await supervisor.lastSpec?.arguments.contains("o1") == true)
    #expect(model.pendingSwitch == nil)
    #expect(model.switchFailure == nil)
    let notice = String(
      decoding: launcher.pane(for: subject.id)?.takePendingNotice() ?? [], as: UTF8.self)
    #expect(notice.contains("Agent switched"))
    #expect(notice.contains("Other Agent (o1)"))
  }

  @Test("A running agent is stopped only once the switch is confirmed, then replaced")
  func runningSessionIsStoppedThenSwitched() async throws {
    let path = folder()
    let subject = session(path: path)
    let (model, launcher, supervisor, repository) = await makeWorkspace(session: subject)
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()

    let sheet = try await openSheet(model, for: subject.id)
    #expect(sheet.confirmTitle == "Stop and Switch")
    #expect(sheet.stopWarning != nil)
    #expect(launcher.isRunning(subject.id))
    sheet.select(model: "deep")

    await model.confirmAgentSwitch()

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.status == .active)
    #expect(stored.agent?.modelID == "deep")
    // Same agent, another model: the conversation goes on.
    #expect(stored.agent?.resumeIdentifier == "kept-identifier")
    #expect(
      await supervisor.lastSpec?.arguments == ["--resume", "kept-identifier", "--model", "deep"])
    #expect(await supervisor.startCount == 2)
  }

  @Test("A refusal while the agent runs leaves it running and writes nothing")
  func refusalLeavesTheRunningAgentAlone() async throws {
    let path = folder()
    let subject = session(path: path)
    let (model, launcher, supervisor, repository) = await makeWorkspace(session: subject)
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    try FileManager.default.removeItem(atPath: path)

    await model.confirmAgentSwitch()

    #expect(launcher.isRunning(subject.id))
    #expect(await supervisor.startCount == 1)
    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.agent == subject.agent)
    #expect(stored.agentHistory.isEmpty)
    #expect(model.switchFailure?.message.contains("no longer exists") == true)
  }

  @Test("A launch that fails puts the session back on its agent, resumable as before")
  func failedLaunchIsReverted() async throws {
    let subject = session(path: folder())
    let supervisor = WorkspaceSupervisor(failure: .spawnFailed(code: 2))
    let (model, _, _, repository) = await makeWorkspace(
      session: subject, supervisor: supervisor)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")

    await model.confirmAgentSwitch()

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.status == .closed)
    #expect(stored.agent == subject.agent)
    #expect(stored.agentHistory.first?.outcome.isFailure == true)
    #expect(model.switchFailure?.message.hasPrefix("Could not switch to Other Agent") == true)
    #expect(model.switchFailure?.suggestion == "The session is back on Stub Agent · Fast.")
    #expect(model.canRestart(stored))
  }

  @Test("A new agent that stops at once, untouched, offers the previous one back")
  func quickFailureOffersTheWayBack() async throws {
    let subject = session(path: folder())
    let (model, _, supervisor, _) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    await model.confirmAgentSwitch()

    // A model the account cannot run: the CLI says so and exits.
    await supervisor.finish(id: subject.id, state: .exited(code: 1))
    await waitUntil { model.switchBackOffers[subject.id] != nil }

    let offer = try #require(model.switchBackOffers[subject.id])
    #expect(offer.target == AgentTarget(providerID: "stub", modelID: "fast"))
    #expect(offer.label == "Stub Agent · Fast")

    // Taking it opens the sheet on that agent: it is a switch like any other, confirmed.
    await waitUntil { model.sessions.first?.status == .closed }
    model.switchBack(subject.id)
    let back = try #require(model.pendingSwitch)
    #expect(back.providerID == "stub")
    #expect(back.modelID == "fast")
  }

  @Test("A stop that cannot be confirmed abandons the switch before anything is written")
  func unconfirmedStopAbandonsTheSwitch() async throws {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor(
      stopState: .failed(.processOutcomeUnknown(processIdentifier: 4242)))
    let (model, launcher, _, repository) = await makeWorkspace(
      session: subject, supervisor: supervisor)
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")

    await model.confirmAgentSwitch()

    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.agent == subject.agent)
    #expect(stored.agentHistory.isEmpty)
    #expect(await supervisor.startCount == 1)
    #expect(model.switchFailure?.message.contains("4242") == true)
    #expect(model.switchFailure?.sessionID == subject.id)
  }

  @Test("Two confirmations start one agent")
  func doubleConfirmationStartsOnce() async throws {
    let subject = session(path: folder())
    let (model, _, supervisor, _) = await makeWorkspace(session: subject)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")

    async let first: Void = model.confirmAgentSwitch()
    async let second: Void = model.confirmAgentSwitch()
    _ = await (first, second)

    #expect(await supervisor.startCount == 1)
  }

  @Test("An archived session is not offered the switch")
  func archivedSessionIsNotOffered() async throws {
    let subject = session(path: folder())
    let (model, _, _, repository) = await makeWorkspace(session: subject)
    await repository.archive(subject.id)
    await model.reload()

    let archived = try #require(model.sessions.first)
    #expect(!model.canSwitchAgent(archived))
    model.beginAgentSwitch(subject.id)
    #expect(model.pendingSwitch == nil)
  }

  @Test("The separator names both agents, or both models")
  func separatorNamesBothSides() throws {
    let path = folder()
    let subject = session(path: path)
    let launch = AgentLaunchPlan(
      providerID: AgentProviderID("other"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: path,
      promptDelivery: .none
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    let agent = SessionLauncher.switchSeparator(
      for: AgentSwitchPlan(
        session: subject, target: AgentTarget(providerID: "other", modelID: "o1"),
        targetName: "Other Agent", plan: launch, mode: .freshWithoutContext),
      previous: "Stub Agent · Fast", at: date)
    #expect(agent.contains("Agent switched"))
    #expect(agent.contains("Stub Agent · Fast → Other Agent (o1) · new process"))

    let model = SessionLauncher.switchSeparator(
      for: AgentSwitchPlan(
        session: subject, target: AgentTarget(providerID: "stub", modelID: "deep"),
        targetName: "Stub Agent", plan: launch, mode: .resumeWithModel(identifier: "x")),
      previous: "Stub Agent · Fast", at: date)
    #expect(model.contains("Model changed"))
    #expect(model.contains("same conversation"))
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    attempts: Int = 200
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}
