import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Switching the agent of a session from the workspace", .timeLimit(.minutes(2)))
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
      legacyNotes: "Keep lodash."
    )
  }

  private func makeWorkspace(
    session: WorkSession,
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor(),
    clock: any SessionClock = SystemSessionClock(),
    history: (any ConversationHandoverExporting)? = nil
  ) async -> (AppModel, SessionLauncher, WorkspaceSupervisor, WorkspaceRepository) {
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: registry,
      viewportTimeout: .zero
    )
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher, clock: clock,
      conversationHandover: history)
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

  /// A copy of the logs that records what the switch asked of it.
  private actor RecordingHistory: ConversationHandoverExporting {
    let isAvailable: Bool
    let isPartial: Bool
    let copies: Bool
    /// Asked when the copy is made: whether the agent writing the logs still runs.
    let probe: (@Sendable () async -> Bool)?
    private(set) var events: [String] = []
    private(set) var runningAtCopy: Bool?

    init(
      available: Bool = true, partial: Bool = false, copies: Bool = true,
      probe: (@Sendable () async -> Bool)? = nil
    ) {
      isAvailable = available
      isPartial = partial
      self.copies = copies
      self.probe = probe
    }

    func availability(of _: WorkSession) -> ConversationHistoryAvailability {
      events.append("availability")
      return ConversationHistoryAvailability(includesLatest: isAvailable, isPartial: isPartial)
    }

    func reserve(for _: WorkSession) -> ConversationHandover {
      events.append("reserve")
      return ConversationHandover(
        index: URL(fileURLWithPath: "/copies/switch/history.md"), byteCount: 0)
    }

    func export(_: WorkSession, into reserved: ConversationHandover) async throws
      -> ConversationHandover
    {
      events.append("export")
      runningAtCopy = await probe?()
      guard copies else { throw ConversationHandoverError.cannotCopy }
      return ConversationHandover(index: reserved.index, byteCount: 4_096)
    }

    func discard(_: ConversationHandover) {
      events.append("discard")
    }
  }

  @Test("History is offered, and chosen by default, only when the logs being left were found")
  func historyIsOfferedWhenAvailable() async throws {
    let subject = session(path: folder())
    let (missing, _, _, _) = await makeWorkspace(
      session: subject, history: RecordingHistory(available: false))
    let without = try await openSheet(missing, for: subject.id)
    await without.select(agent: "other")
    #expect(!without.offersConversationHistory)
    #expect(without.contextChoices == [.summary])
    #expect(!without.offersContextChoice)
    #expect(without.handover == .summary)
    #expect(without.canSwitch)

    let (found, _, _, _) = await makeWorkspace(session: subject, history: RecordingHistory())
    let with = try await openSheet(found, for: subject.id)
    await with.select(agent: "other")
    #expect(with.contextChoices == [.history, .summary])
    #expect(with.offersContextChoice)
    #expect(with.handover == .conversationHistory)
    #expect(with.expectedModeKind == .conversationHistory)
    #expect(with.continuityNotice.contains("copies"))
    #expect(!with.continuityNotice.contains("partial"))

    let (partial, _, _, _) = await makeWorkspace(
      session: subject, history: RecordingHistory(partial: true))
    let incomplete = try await openSheet(partial, for: subject.id)
    await incomplete.select(agent: "other")
    #expect(incomplete.continuityNotice.contains("history is partial"))
  }

  @Test("The logs are copied once the running agent has stopped, and the copy is recorded")
  func historyIsCopiedAfterTheStop() async throws {
    let path = folder()
    let subject = session(path: path)
    let supervisor = WorkspaceSupervisor()
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let id = subject.id
    let history = RecordingHistory(probe: { await launcher.isRunning(id) })
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      conversationHandover: history)
    await model.reload()
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()

    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    #expect(sheet.handover == .conversationHistory)
    await model.confirmAgentSwitch()

    #expect(model.switchFailure == nil)
    #expect(await history.runningAtCopy == false)
    #expect(await history.events == ["availability", "availability", "reserve", "export"])
    let stored = try #require(await repository.session(id: subject.id))
    #expect(stored.agent?.providerID == "other")
    #expect(stored.agentHistory.last?.handover == .conversationHistory(byteCount: 4_096))
    #expect(
      await supervisor.lastSpec?.arguments.contains { $0.contains("/copies/switch/history.md") }
        == true)
  }

  @Test("A copy that fails leaves the session on its agent, and Switch Agent opens on the target")
  func failedCopyIsRefused() async throws {
    let subject = session(path: folder())
    let history = RecordingHistory(copies: false)
    let (model, _, supervisor, repository) = await makeWorkspace(
      session: subject, history: history)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    await model.confirmAgentSwitch()

    let failure = try #require(model.switchFailure)
    #expect(failure.message.contains("could not be copied"))
    #expect(failure.suggestion != nil)
    #expect(failure.switchTarget == AgentTarget(providerID: "other"))
    let unchanged = try #require(await repository.session(id: subject.id))
    #expect(unchanged.agent == subject.agent)
    #expect(unchanged.agentHistory.isEmpty)
    #expect(await supervisor.startCount == 0)

    model.beginAgentSwitch(subject.id, preselected: failure.switchTarget)
    #expect(model.pendingSwitch?.providerID == "other")
  }

  @Test("A launch that fails removes the copy no agent will read")
  func failedLaunchDiscardsTheCopy() async throws {
    let subject = session(path: folder())
    let history = RecordingHistory()
    let (model, _, _, repository) = await makeWorkspace(
      session: subject, supervisor: WorkspaceSupervisor(failure: .spawnFailed(code: 2)),
      history: history)
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    await model.confirmAgentSwitch()

    #expect(await history.events.suffix(2) == ["export", "discard"])
    #expect(await repository.session(id: subject.id)?.agent == subject.agent)
  }

  @Test("A model change can resume, copy the history or start from the editable summary")
  func modelChangeContextChoice() async throws {
    let subject = session(path: folder())
    let (model, _, _, repository) = await makeWorkspace(
      session: subject, history: RecordingHistory(copies: false))
    let sheet = try await openSheet(model, for: subject.id)
    sheet.select(model: "deep")
    #expect(sheet.offersContextChoice)
    #expect(sheet.contextChoices == [.resume, .history, .summary])
    #expect(sheet.contextChoice == .resume)
    #expect(sheet.expectedModeKind == .resumeWithModel)

    sheet.contextChoice = .history
    #expect(sheet.handover == .conversationHistory)
    #expect(sheet.skipsResume)
    #expect(sheet.expectedModeKind == .conversationHistory)
    await model.confirmAgentSwitch()
    // The copy fails: a silent native resume would have launched instead.
    #expect(model.switchFailure?.message.contains("could not be copied") == true)
    #expect(await repository.session(id: subject.id)?.agent == subject.agent)

    let summary = try await openSheet(model, for: subject.id)
    summary.select(model: "deep")
    summary.contextChoice = .summary
    summary.summaryText = "Continue from the parser tests."
    #expect(summary.handover == .summary)
    #expect(summary.expectedModeKind == .handover)
    #expect(summary.skipsResume)
    #expect(!summary.continuityNotice.contains("stopped as soon"))
    await model.confirmAgentSwitch()
    let switched = try #require(await repository.session(id: subject.id))
    #expect(switched.agent?.modelID == "deep")
    #expect(switched.agent?.resumeIdentifier != subject.agent?.resumeIdentifier)
    guard case .summary(_, _, let edited) = switched.agentHistory.last?.handover else {
      Issue.record("Expected an edited summary instead of native resume")
      return
    }
    #expect(edited)
  }

  @Test("The explicit context choice survives model changes and can return to native resume")
  func contextChoiceSurvivesModelSelection() async throws {
    let subject = session(path: folder())
    let (model, _, _, _) = await makeWorkspace(session: subject, history: RecordingHistory())
    let sheet = try await openSheet(model, for: subject.id)
    sheet.contextChoice = .summary
    sheet.summaryText = "Keep these instructions."
    sheet.select(model: "deep")
    #expect(sheet.contextChoice == .summary)
    #expect(sheet.summaryText == "Keep these instructions.")
    sheet.contextChoice = .history
    sheet.select(model: nil)
    #expect(sheet.contextChoice == .history)
    sheet.contextChoice = .resume
    #expect(sheet.handover == .resumesConversation)
    #expect(!sheet.skipsResume)
    // Another agent cannot resume: the default is back, and the choice holds on return.
    await sheet.select(agent: "other")
    #expect(!sheet.canResumeConversation)
    #expect(sheet.contextChoice == .history)
    await sheet.select(agent: "stub")
    #expect(sheet.contextChoice == .resume)
  }

  @Test("An agent that takes no prompt still asks whether to retry a dropped conversation")
  func failedResumeRetryWithoutPrompt() async throws {
    let subject = session(path: folder())
    var silent = Self.stub
    silent.takesInitialPrompt = false
    let registry = WorkspaceRegistry(providers: [silent, Self.other])
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
    #expect(!sheet.offersContextChoice)
    #expect(sheet.offersResumeRetry)
    #expect(sheet.handover == .nothing)
    sheet.retriesFailedResume = true
    #expect(sheet.handover == .resumesConversation)
    #expect(sheet.expectedModeKind == .resumeWithModel)
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
    #expect(stored.legacyNotes == subject.legacyNotes)
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
    // The clock stands still: a runner frozen past the probation would make the exit an ordinary
    // end of work, and the switch back would never be offered.
    let (model, _, supervisor, _) = await makeWorkspace(
      session: subject, clock: SteppableClock(Date()))
    let sheet = try await openSheet(model, for: subject.id)
    await sheet.select(agent: "other")
    await model.confirmAgentSwitch()

    // A model the account cannot run: the CLI says so and exits.
    await supervisor.finish(id: subject.id, state: .exited(code: 1))
    await waitUntil("the switch back is offered") { model.switchBackOffers[subject.id] != nil }

    let offer = try #require(model.switchBackOffers[subject.id])
    #expect(offer.target == AgentTarget(providerID: "stub", modelID: "fast"))
    #expect(offer.label == "Stub Agent · Fast")

    // Taking it opens the sheet on that agent: it is a switch like any other, confirmed.
    await waitUntil("the session is closed") { model.sessions.first?.status == .closed }
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
}
