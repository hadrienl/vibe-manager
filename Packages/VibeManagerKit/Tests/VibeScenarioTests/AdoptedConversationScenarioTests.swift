import Foundation
import Testing
import VibeAgents
import VibeApplication
import VibeDomain
import VibePersistence

@testable import VibeUI

// A Claude Code session started without a prompt, left running in the terminal host before anyone
// wrote to it, and written to once the application is back (#141). Two launchers stand for the two
// instances of the application, one after the other; the host is a double that keeps its
// terminals between them, and the transcript is a real file under a temporary projects directory.

/// A terminal the terminal host runs, as far as the launcher can tell.
private actor KeptTerminal: HostedTerminal {
  nonisolated let id: TerminalID
  private var current: TerminalProcessState
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: TerminalID, state: TerminalProcessState) {
    self.id = id
    current = state
  }

  func attach() -> TerminalAttachment {
    var continuation: AsyncStream<TerminalEvent>.Continuation?
    let events = AsyncStream<TerminalEvent> { continuation = $0 }
    if let continuation {
      if current.isFinished {
        continuation.finish()
      } else {
        continuations.append(continuation)
      }
    }
    return TerminalAttachment(
      state: current, history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: events)
  }

  func state() -> TerminalProcessState { current }

  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }

  func write(_ bytes: [UInt8]) {}

  func resize(to size: TerminalSize) {}

  func stop(gracePeriod: Duration) { finish(state: .exited(code: 0)) }

  func kill() { finish(state: .terminated(signal: 9)) }

  func finish(state: TerminalProcessState) {
    guard !current.isFinished else { return }
    current = state
    for continuation in continuations {
      continuation.yield(.stateChanged(state))
      continuation.finish()
    }
    continuations.removeAll()
  }
}

/// The terminal host: it keeps what it started across the two instances.
private actor KeepingHost: TerminalSupervisor {
  private var terminals: [TerminalID: KeptTerminal] = [:]

  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    let terminal = KeptTerminal(id: id, state: .running(processIdentifier: 7_001))
    terminals[id] = terminal
    return terminal
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { terminals[id] }

  func terminal(for id: SessionID) -> KeptTerminal? { terminals[id.agentTerminal] }

  func stop(id: TerminalID, gracePeriod: Duration) async {
    await terminals[id]?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) {}
}

/// Claude Code as the launcher sees it, its transcripts under a projects directory of the test's.
private struct TranscribedClaude: AgentProvider, AgentLaunchObserverProviding {
  let projects: URL

  var descriptor: AgentDescriptor { ClaudeCodeAgentProvider.descriptor }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "Claude Code is ready.", probedAt: Date(timeIntervalSince1970: 0),
        remediations: []))
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw CancellationError()
  }

  func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver {
    ClaudeCodeLaunchObserver(
      capture: ClaudeCodeSessionIdentifierCapture(
        sessionID: sessionID,
        record: RecordAgentResumeIdentifier(
          repository: repository, providerID: descriptor.id.rawValue, launchedAt: Date()),
        transcripts: ClaudeCodeTranscriptWatcher(
          projectsDirectory: projects, pollInterval: .milliseconds(20))))
  }
}

@MainActor
@Suite("A Claude Code conversation begun after a relaunch")
struct AdoptedConversationScenarioTests {
  private let identifier = "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04"

  /// Everything both instances share: the store, the runtime document, the host, the disk.
  @MainActor
  private final class World {
    let projects: URL
    let project: URL
    let session: WorkSession
    let repository: InMemorySessionRepository
    let runtime = EphemeralSessionRuntimeStateStore()
    let host = KeepingHost()
    let agents: AgentProviderRegistry

    init() throws {
      projects = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("claude-projects-\(UUID().uuidString)", isDirectory: true)
      project = projects.appendingPathComponent("-workspace", isDirectory: true)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      session = WorkSession(
        name: "Premier message après la relance",
        agent: SessionAgentConfiguration(providerID: ClaudeCodeAgentProvider.id.rawValue),
        status: .closed,
        repositories: [RepositoryContext(path: "/workspace")]
      )
      repository = InMemorySessionRepository(sessions: [session])
      agents = AgentProviderRegistry(providers: [TranscribedClaude(projects: projects)])
    }

    deinit { try? FileManager.default.removeItem(at: projects) }

    @MainActor
    func instance(processIdentifier: Int32) -> (SessionLauncher, SessionRuntimeRecorder) {
      let recorder = SessionRuntimeRecorder(store: runtime, processIdentifier: processIdentifier)
      let launcher = SessionLauncher(
        supervisor: host, repository: repository, agents: agents, recorder: recorder,
        viewportTimeout: .zero)
      return (launcher, recorder)
    }

    /// The first message: Claude Code files the conversation under its identifier.
    func writeTranscript(_ identifier: String) throws {
      try Data("{}\n".utf8).write(
        to: project.appendingPathComponent("\(identifier).jsonl", isDirectory: false))
    }

    func storedIdentifier() async -> String? {
      await repository.session(id: session.id)?.agent?.resumeIdentifier
    }
  }

  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: ClaudeCodeAgentProvider.id,
      executablePath: "/usr/local/bin/claude",
      arguments: ["--session-id", identifier],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .none
    )
  }

  /// Launched without a prompt, never written to, and left running on quit.
  private func launchAndLeaveRunning(in world: World) async {
    let (launcher, recorder) = world.instance(processIdentifier: 1_001)
    await recorder.claim()
    #expect(await launcher.launch(session: world.session, plan: plan()))
    #expect(await launcher.handOff(world.session.id))
    await recorder.markDetached(keeping: [world.session.id], resuming: [], host: nil)
  }

  @Test("Written to after the relaunch, the conversation can be resumed (#141)")
  func conversationBegunAfterTheRelaunchIsStored() async throws {
    let world = try World()
    await launchAndLeaveRunning(in: world)
    #expect(await world.storedIdentifier() == nil)

    let (launcher, recorder) = world.instance(processIdentifier: 1_002)
    await recorder.claim()
    #expect(await launcher.adopt(world.session))
    try world.writeTranscript(identifier)

    #expect(await eventually { await world.storedIdentifier() == identifier })
  }

  @Test("An agent that ended while away is looked at once, for the conversation it began")
  func conversationOfAnAgentEndedWhileAwayIsStored() async throws {
    let world = try World()
    await launchAndLeaveRunning(in: world)
    // Written to in the terminal, then quit, while the application was closed.
    try world.writeTranscript(identifier)
    await world.host.terminal(for: world.session.id)?.finish(state: .exited(code: 0))

    let (launcher, recorder) = world.instance(processIdentifier: 1_002)
    await recorder.claim()
    #expect(await launcher.adopt(world.session))

    #expect(await world.storedIdentifier() == identifier)
  }

  @Test("Still unwritten, the identifier is handed on again, and never stored without its file")
  func stillUnwrittenIsHandedOnAgain() async throws {
    let world = try World()
    await launchAndLeaveRunning(in: world)

    let (launcher, recorder) = world.instance(processIdentifier: 1_002)
    await recorder.claim()
    #expect(await launcher.adopt(world.session))
    #expect(await launcher.handOff(world.session.id))
    await recorder.markDetached(keeping: [world.session.id], resuming: [], host: nil)

    #expect(
      await world.runtime.read()?.sessions.first?.awaitedResumeIdentifier == identifier)
    #expect(await world.storedIdentifier() == nil)

    // The third instance sees the agent quit without a word: nothing to resume.
    let (third, thirdRecorder) = world.instance(processIdentifier: 1_003)
    await thirdRecorder.claim()
    #expect(await third.adopt(world.session))
    await world.host.terminal(for: world.session.id)?.finish(state: .exited(code: 0))

    #expect(
      await eventually { await world.repository.session(id: world.session.id)?.status == .closed })
    #expect(await world.storedIdentifier() == nil)
  }
}
