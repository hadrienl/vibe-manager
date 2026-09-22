import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Launching a created session")
struct SessionLauncherTests {
  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: ["--session-id", "abc"],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .argument
    )
  }

  private func storedSession() -> WorkSession {
    WorkSession(
      name: "Refactor the webhook",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .closed,
      repositories: [RepositoryContext(path: "/workspace")]
    )
  }

  @Test("A running session is never launched twice")
  func doubleLaunchIsRefused() async {
    let supervisor = SpySupervisor()
    let repository = MutableRepository(sessions: [storedSession()])
    let launcher = SessionLauncher(
      supervisor: supervisor,
      repository: repository,
      agents: EmptyRegistry(),
      viewportTimeout: .zero
    )
    let session = await repository.sessions().first!

    await launcher.launch(session: session, plan: plan())
    await launcher.launch(session: session, plan: plan())

    #expect(await supervisor.startCount == 1)
  }

  @Test("A launched session becomes active and keeps its pane")
  func successfulLaunchActivatesTheSession() async {
    let repository = MutableRepository(sessions: [storedSession()])
    let launcher = SessionLauncher(
      supervisor: SpySupervisor(),
      repository: repository,
      agents: EmptyRegistry(),
      viewportTimeout: .zero
    )
    let session = await repository.sessions().first!

    let launched = await launcher.launch(session: session, plan: plan())

    #expect(launched)
    #expect(launcher.pane(for: session.id) != nil)
    #expect(await repository.session(id: session.id)?.status == .active)
  }

  @Test("A launch that fails keeps the session, closed, with its failure readable")
  func failedLaunchKeepsTheSession() async {
    let repository = MutableRepository(sessions: [storedSession()])
    let launcher = SessionLauncher(
      supervisor: SpySupervisor(failure: .resourceLimitReached(code: 35)),
      repository: repository,
      agents: EmptyRegistry(),
      viewportTimeout: .zero
    )
    let session = await repository.sessions().first!

    let launched = await launcher.launch(session: session, plan: plan())

    #expect(!launched)
    #expect(await repository.session(id: session.id)?.status == .closed)
    let failure = launcher.failure(for: session.id)
    #expect(failure?.message.isEmpty == false)
    #expect(failure?.suggestion?.isEmpty == false)
  }

  @Test("The plan's prompt is typed only when the agent asked for the standard input")
  func promptDeliveryDecidesTheInitialInput() {
    let argument = TerminalSpec.agent(plan: plan())
    #expect(argument.initialInput == nil)
    #expect(argument.arguments == ["--session-id", "abc"])

    let typed = TerminalSpec.agent(
      plan: AgentLaunchPlan(
        providerID: AgentProviderID("stub"),
        executablePath: "/usr/bin/true",
        arguments: [],
        environment: [:],
        workingDirectoryPath: "/workspace",
        promptDelivery: .standardInput("Fix the tests\n")
      )
    )
    #expect(typed.initialInput == "Fix the tests\n")
  }

  @Test("A created session is published and selected even when its launch fails")
  func creationSurvivesAFailedLaunch() async {
    let session = storedSession()
    let repository = MutableRepository(sessions: [session])
    let launcher = SessionLauncher(
      supervisor: SpySupervisor(failure: .resourceLimitReached(code: 35)),
      repository: repository,
      agents: EmptyRegistry(),
      viewportTimeout: .zero
    )
    let model = AppModel(repository: repository, agents: EmptyRegistry(), launcher: launcher)

    await model.complete(SessionCreation(session: session, plan: plan()))

    #expect(model.selectedSessionID == session.id)
    #expect(model.sessions.map(\.id) == [session.id])
    #expect(!model.isPresentingNewSession)
  }
}

private actor MutableRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private actor SpySupervisor: TerminalSupervisor {
  private(set) var startCount = 0
  private var sessions: [SessionID: FakeTerminalSession] = [:]
  private let failure: TerminalError?

  init(failure: TerminalError? = nil) {
    self.failure = failure
  }

  func start(_ spec: TerminalSpec, for id: SessionID) throws -> any TerminalSession {
    if let failure { throw failure }
    startCount += 1
    let session = FakeTerminalSession(id: id)
    sessions[id] = session
    return session
  }

  func session(for id: SessionID) -> (any TerminalSession)? { sessions[id] }

  func stop(id: SessionID, gracePeriod: Duration) {}

  func stopAll(gracePeriod: Duration) {}
}

private actor FakeTerminalSession: TerminalSession {
  nonisolated let id: SessionID

  init(id: SessionID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    TerminalAttachment(
      state: .running(processIdentifier: 4242),
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: AsyncStream { $0.finish() }
    )
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 4242) }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) {}

  func kill() {}
}

private struct EmptyRegistry: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [] }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? { nil }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}
