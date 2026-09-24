import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Recording the runs a launcher starts")
struct SessionUsageRecordingTests {
  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .none
    )
  }

  private func session() -> WorkSession {
    WorkSession(
      name: "Usage",
      agent: SessionAgentConfiguration(providerID: "stub", modelID: "big"),
      status: .closed,
      repositories: [RepositoryContext(path: "/workspace")]
    )
  }

  private func makeLauncher(
    _ subject: WorkSession
  ) -> (SessionLauncher, WorkspaceSupervisor, InMemoryUsageLedger) {
    let supervisor = WorkspaceSupervisor()
    let ledger = InMemoryUsageLedger()
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: WorkspaceRepository(sessions: [subject]),
      agents: WorkspaceRegistry(providers: []),
      usage: UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore()),
      viewportTimeout: .zero
    )
    return (launcher, supervisor, ledger)
  }

  private func runs(_ ledger: InMemoryUsageLedger) async -> [UsageRun] {
    UsageLedgerFold.runs(from: await ledger.events())
  }

  @Test("A launch is a start with the session's model, and its exit ends it once")
  func launchAndExit() async {
    let subject = session()
    let (launcher, supervisor, ledger) = makeLauncher(subject)
    var closed = false
    launcher.sessionDidClose = { _, _ in closed = true }

    await launcher.launch(session: subject, plan: plan())
    await supervisor.finish(id: subject.id, state: .exited(code: 0))
    for _ in 0..<200 where !closed { try? await Task.sleep(for: .milliseconds(5)) }
    _ = await launcher.detach(subject.id)

    let recorded = await runs(ledger)
    #expect(recorded.count == 1)
    #expect(recorded.first?.kind == .start)
    #expect(recorded.first?.modelID == "big")
    #expect(recorded.first?.providerID == "stub")
    #expect(recorded.first?.exit == .exited)
  }

  @Test("An agent that exits at once still has its run closed")
  func immediateExit() async {
    let subject = session()
    let supervisor = WorkspaceSupervisor(initialState: .exited(code: 1))
    let ledger = InMemoryUsageLedger()
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: WorkspaceRepository(sessions: [subject]),
      agents: WorkspaceRegistry(providers: []),
      usage: UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore()),
      viewportTimeout: .zero
    )
    var closed = false
    launcher.sessionDidClose = { _, _ in closed = true }

    await launcher.launch(session: subject, plan: plan())
    for _ in 0..<200 where !closed { try? await Task.sleep(for: .milliseconds(5)) }

    let recorded = await runs(ledger)
    #expect(closed)
    #expect(recorded.allSatisfy { !$0.isOpen })
  }

  @Test("A native restart through the restoration is a resume after relaunch")
  func restorationIsAResume() async {
    let subject = session()
    let (launcher, _, ledger) = makeLauncher(subject)

    _ = await launcher.attemptRestart(
      SessionRestart(
        session: subject, plan: plan(), mode: .native(identifier: "abc"), explanation: nil))

    let recorded = await runs(ledger)
    #expect(recorded.first?.kind == .resume)
    #expect(recorded.first?.afterRelaunch == true)
    #expect(recorded.first?.isOpen == true)
  }

  @Test("Closing the session stops the run")
  func detachStops() async {
    let subject = session()
    let (launcher, _, ledger) = makeLauncher(subject)

    await launcher.launch(session: subject, plan: plan())
    _ = await launcher.detach(subject.id)

    #expect(await runs(ledger).first?.exit == .stopped)
  }

  @Test("A launch that never starts records nothing")
  func failedLaunch() async {
    let subject = session()
    let ledger = InMemoryUsageLedger()
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(failure: .resourceLimitReached(code: 35)),
      repository: WorkspaceRepository(sessions: [subject]),
      agents: WorkspaceRegistry(providers: []),
      usage: UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore()),
      viewportTimeout: .zero
    )

    await launcher.launch(session: subject, plan: plan())

    #expect(await ledger.events().isEmpty)
  }

  @Test("Restart and switch modes map to their kind")
  func kinds() {
    #expect(SessionLauncher.usageKind(for: SessionRestartMode.firstLaunch) == .start)
    #expect(SessionLauncher.usageKind(for: SessionRestartMode.freshWithoutContext) == .restartFresh)
    #expect(
      SessionLauncher.usageKind(for: AgentSwitchMode.resumeWithModel(identifier: "x")) == .resume)
    #expect(SessionLauncher.usageKind(for: AgentSwitchMode.freshWithoutContext) == .restartFresh)
  }

  @Test("Figures read in words")
  func presentation() {
    var counts = UsageRunCounts()
    #expect(UsagePresentation.runs(counts) == "None recorded")
    counts.starts = 2
    counts.resumes = 5
    counts.afterRelaunch = 2
    counts.afterSwitch = 1
    #expect(UsagePresentation.runs(counts) == "2 starts · 5 resumes (2 after relaunch) · 1 switch")
    #expect(UsagePresentation.duration(3 * 3_600 + 12 * 60) == "3 h 12 min")
    #expect(UsagePresentation.duration(20) == "< 1 min")
    #expect(UsagePresentation.tokens(1_234_567) == "1.2 M")
    #expect(UsagePresentation.tokens(48_000) == "48.0 k")
  }
}
