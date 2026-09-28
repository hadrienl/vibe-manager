import Foundation
import Testing
import VibeAgents
import VibeApplication
import VibeDomain
import VibePersistence

@testable import VibeUI

// Codex begins its session with its process but names it only with the first message, when it
// writes the rollout and runs its `SessionStart` hook (#144). The launchers below are the real
// ones, with the real Codex observer, activity decoder and rollout discovery, on a temporary
// `CODEX_HOME`; the terminal host is a double that keeps its terminals, and the hooks' lines are
// written into each session's log as Codex would write them.

/// A terminal the terminal host runs, as far as the launcher can tell.
private actor CodexTerminal: HostedTerminal {
  nonisolated let id: TerminalID
  private var current: TerminalProcessState = .running(processIdentifier: 7_101)
  private var continuations: [AsyncStream<TerminalEvent>.Continuation] = []

  init(id: TerminalID) {
    self.id = id
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

/// The terminal host: it keeps what it started across the instances.
private actor CodexHost: TerminalSupervisor {
  private var terminals: [TerminalID: CodexTerminal] = [:]

  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    let terminal = CodexTerminal(id: id)
    terminals[id] = terminal
    return terminal
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { terminals[id] }

  func stop(id: TerminalID, gracePeriod: Duration) async {
    await terminals[id]?.finish(state: .exited(code: 0))
  }

  func stopAll(gracePeriod: Duration) {}
}

/// Codex, whose hooks this test takes as approved: asking `codex app-server` is not its subject.
private struct ApprovedCodex: AgentProvider, AgentActivityReporting, AgentLaunchObserverProviding {
  let codex: CodexAgentProvider

  var descriptor: AgentDescriptor { CodexAgentProvider.descriptor }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    await codex.availability(forceRefresh: forceRefresh)
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw CancellationError()
  }

  func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    codex.reportingActivity(plan, to: log)
  }

  func activityDecoder() -> any AgentSignalDecoding {
    CodexSignalDecoder()
  }

  func activityDecoder(workingDirectoryPath: String?, environment: [String: String])
    -> any AgentSignalDecoding
  {
    CodexSignalDecoder()
  }

  func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver {
    codex.launchObserver(for: sessionID, repository: repository)
  }
}

@MainActor
@Suite("A Codex conversation named by its own hooks", .serialized)
struct CodexConversationScenarioTests {
  /// Everything the instances share: the store, the runtime document, the host, the disk.
  @MainActor
  private final class World {
    let root: URL
    let codexHome: URL
    let day: URL
    let activityLogs: URL
    let workingDirectory: String
    let repository: InMemorySessionRepository
    let runtime = EphemeralSessionRuntimeStateStore()
    let host = CodexHost()
    let agents: AgentProviderRegistry

    init(sessions: [WorkSession]) throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-conversation-\(UUID().uuidString)", isDirectory: true)
      codexHome = root.appendingPathComponent("codex", isDirectory: true)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
      let today = calendar.dateComponents([.year, .month, .day], from: Date())
      day = codexHome.appendingPathComponent(
        String(
          format: "sessions/%04d/%02d/%02d", today.year ?? 2026, today.month ?? 1, today.day ?? 1),
        isDirectory: true)
      activityLogs = root.appendingPathComponent("AgentActivity", isDirectory: true)
      let work = root.appendingPathComponent("dépôt", isDirectory: true)
      try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      workingDirectory = work.path
      repository = InMemorySessionRepository(sessions: sessions)
      agents = AgentProviderRegistry(providers: [
        ApprovedCodex(codex: CodexAgentProvider.make(environment: ["CODEX_HOME": codexHome.path]))
      ])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor
    func instance(processIdentifier: Int32) -> (SessionLauncher, SessionRuntimeRecorder) {
      let recorder = SessionRuntimeRecorder(store: runtime, processIdentifier: processIdentifier)
      let tracker = TrackAgentActivity(
        logs: FileAgentActivityLog(directory: activityLogs), store: MemoryActivityStates())
      let launcher = SessionLauncher(
        supervisor: host, repository: repository, agents: agents, recorder: recorder,
        activity: tracker,
        reportActivity: ReportAgentActivity(
          agents: agents, tracker: tracker, consents: InMemoryAgentHookConsentStore()),
        viewportTimeout: .zero)
      return (launcher, recorder)
    }

    func plan() -> AgentLaunchPlan {
      AgentLaunchPlan(
        providerID: CodexAgentProvider.id,
        executablePath: "/usr/local/bin/codex",
        arguments: ["-C", workingDirectory],
        environment: ["CODEX_HOME": codexHome.path],
        workingDirectoryPath: workingDirectory,
        promptDelivery: .none
      )
    }

    /// The first message sent to the agent of `session`: Codex writes the rollout of the session
    /// its process began at `startedAt`, then runs its `SessionStart` hook.
    func firstMessage(to session: WorkSession, names identifier: String, startedAt: Date) throws {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let meta = """
        {"timestamp":"\(formatter.string(from: Date()))","type":"session_meta","payload":\
        {"id":"\(identifier)","timestamp":"\(formatter.string(from: startedAt))",\
        "cwd":"\(workingDirectory)","originator":"codex-tui","cli_version":"0.157.1"}}

        """
      try meta.write(
        to: day.appendingPathComponent("rollout-2026-09-28T02-57-54-\(identifier).jsonl"),
        atomically: true, encoding: .utf8)

      let log = activityLogs.appendingPathComponent(
        "\(session.id.rawValue.uuidString).log", isDirectory: false)
      let line =
        "SessionStart\t\(Int(Date().timeIntervalSince1970))\t{\"session_id\":\"\(identifier)\"}\n"
      let handle = try FileHandle(forWritingTo: log)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
      try handle.close()
    }

    func storedIdentifier(of session: WorkSession) async -> String? {
      await repository.session(id: session.id)?.agent?.resumeIdentifier
    }
  }

  private static func codexSession(_ name: String) -> WorkSession {
    WorkSession(
      name: name,
      agent: SessionAgentConfiguration(providerID: CodexAgentProvider.id.rawValue),
      status: .closed,
      repositories: [RepositoryContext(path: "/workspace")]
    )
  }

  private static func newIdentifier() -> String {
    UUID().uuidString.lowercased()
  }

  @Test("Two Codex panes in the same folder each keep their own conversation (#144)")
  func twoPanesInTheSameFolderKeepTheirOwn() async throws {
    let first = Self.codexSession("Premier panneau")
    let second = Self.codexSession("Second panneau")
    let world = try World(sessions: [first, second])
    let (launcher, recorder) = world.instance(processIdentifier: 2_001)
    await recorder.claim()
    let firstStarted = Date()
    #expect(await launcher.launch(session: first, plan: world.plan()))
    let secondStarted = Date()
    #expect(await launcher.launch(session: second, plan: world.plan()))

    // The second pane is written to first: its rollout is the oldest one of the folder.
    let secondConversation = Self.newIdentifier()
    let firstConversation = Self.newIdentifier()
    try world.firstMessage(to: second, names: secondConversation, startedAt: secondStarted)
    try world.firstMessage(to: first, names: firstConversation, startedAt: firstStarted)

    #expect(
      await eventually {
        let firstStored = await world.storedIdentifier(of: first)
        let secondStored = await world.storedIdentifier(of: second)
        return firstStored == firstConversation && secondStored == secondConversation
      })
    await launcher.stopAll(gracePeriod: .zero)
  }

  @Test("A pane started after the relaunch never takes the conversation of the one left running")
  func paneStartedAfterTheRelaunchKeepsToItsOwn() async throws {
    let kept = Self.codexSession("Laissé tourner")
    let fresh = Self.codexSession("Ouvert après la relance")
    let world = try World(sessions: [kept, fresh])
    let (launcher, recorder) = world.instance(processIdentifier: 2_201)
    await recorder.claim()
    #expect(await launcher.launch(session: kept, plan: world.plan()))
    #expect(await launcher.handOff(kept.id))
    await recorder.markDetached(keeping: [kept.id], resuming: [], host: nil)
    // The previous instance started it a minute before this one opened.
    let keptStarted = Date().addingTimeInterval(-60)

    let (next, nextRecorder) = world.instance(processIdentifier: 2_202)
    await nextRecorder.claim()
    #expect(await next.adopt(kept))
    #expect(await next.launch(session: fresh, plan: world.plan()))
    // The pane left running is written to first: its rollout appears after the new launch, in the
    // folder the new pane is looking at.
    let keptConversation = Self.newIdentifier()
    try world.firstMessage(to: kept, names: keptConversation, startedAt: keptStarted)
    #expect(await eventually { await world.storedIdentifier(of: kept) == keptConversation })

    let freshConversation = Self.newIdentifier()
    try world.firstMessage(to: fresh, names: freshConversation, startedAt: Date())
    #expect(await eventually { await world.storedIdentifier(of: fresh) == freshConversation })
    #expect(await world.storedIdentifier(of: kept) == keptConversation)
    await next.stopAll(gracePeriod: .zero)
  }

  @Test("Named after a relaunch, the conversation of a pane left running is stored (#144)")
  func conversationNamedAfterTheRelaunchIsStored() async throws {
    let session = Self.codexSession("Laissé tourner")
    let world = try World(sessions: [session])
    let (launcher, recorder) = world.instance(processIdentifier: 2_101)
    await recorder.claim()
    let started = Date()
    #expect(await launcher.launch(session: session, plan: world.plan()))
    // Nobody wrote to it before quitting, and it was left running.
    #expect(await launcher.handOff(session.id))
    await recorder.markDetached(keeping: [session.id], resuming: [], host: nil)
    #expect(await world.storedIdentifier(of: session) == nil)

    let (next, nextRecorder) = world.instance(processIdentifier: 2_102)
    await nextRecorder.claim()
    #expect(await next.adopt(session))
    let conversation = Self.newIdentifier()
    try world.firstMessage(to: session, names: conversation, startedAt: started)

    #expect(await eventually { await world.storedIdentifier(of: session) == conversation })
    await next.stopAll(gracePeriod: .zero)
  }
}

/// Where the tracker writes its states: kept in memory, a test's run long.
private actor MemoryActivityStates: AgentActivityStateStore {
  private var stored: [SessionID: PersistedAgentActivity] = [:]

  func read() -> [SessionID: PersistedAgentActivity] { stored }

  func write(_ activities: [SessionID: PersistedAgentActivity]) { stored = activities }
}
