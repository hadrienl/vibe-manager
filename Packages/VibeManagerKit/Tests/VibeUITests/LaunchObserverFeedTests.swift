import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A terminal that says what each subscriber asked to read, and serves each only that.
private actor InterestTerminal: TerminalSession {
  nonisolated let id = TerminalID()
  private var subscribers:
    [UUID: (interest: TerminalEventInterest, continuation: AsyncStream<TerminalEvent>.Continuation)] =
      [:]
  private(set) var interests: [TerminalEventInterest] = []
  private var current = TerminalProcessState.running(processIdentifier: 7)
  let lastOutput = ContinuousClock.now

  func attach() -> TerminalAttachment { attach(.everything) }

  func attach(_ interest: TerminalEventInterest) -> TerminalAttachment {
    interests.append(interest)
    let (events, continuation) = AsyncStream<TerminalEvent>.makeStream()
    if current.isFinished {
      continuation.finish()
    } else {
      let subscriberID = UUID()
      subscribers[subscriberID] = (interest, continuation)
      continuation.onTermination = { _ in Task { await self.remove(subscriberID) } }
    }
    return TerminalAttachment(
      state: current, history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: events)
  }

  private func remove(_ subscriberID: UUID) {
    subscribers[subscriberID] = nil
  }

  /// How many subscribers still read the bytes.
  var byteReaders: Int {
    subscribers.values.filter { $0.interest == .everything }.count
  }

  func lastOutputAt() -> ContinuousClock.Instant? { lastOutput }

  func print(_ text: String) {
    for (interest, continuation) in subscribers.values {
      if let event = interest.translating(.output([UInt8](text.utf8))) {
        continuation.yield(event)
      }
    }
  }

  func end() {
    current = .exited(code: 0)
    for (_, continuation) in subscribers.values {
      continuation.yield(.stateChanged(current))
      continuation.finish()
    }
    subscribers.removeAll()
  }

  func state() -> TerminalProcessState { current }
  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }
  func write(_ bytes: [UInt8]) {}
  func resize(to size: TerminalSize) {}
  func stop(gracePeriod: Duration) { end() }
  func kill() { end() }
}

/// An observer that reads until it has seen `wanted`, and says so.
private actor ReadingObserver: AgentLaunchObserver {
  nonisolated let readsOutput: Bool
  private let wanted: String
  private(set) var read = ""

  init(readsOutput: Bool = true, wanted: String) {
    self.readsOutput = readsOutput
    self.wanted = wanted
  }

  func launched(plan _: AgentLaunchPlan) async {}

  func observe(output: String) async -> AgentOutputDemand {
    read += output
    return read.contains(wanted) ? .enough : .more
  }

  func finished() async {}
}

@Suite("What the launcher hands an agent's observer (#248)")
struct LaunchObserverFeedTests {
  @Test("An observer that reads nothing is never handed a byte, and still hears the end")
  func silentObserverOnlyWaitsForTheEnd() async {
    let terminal = InterestTerminal()
    let observer = ReadingObserver(readsOutput: false, wanted: "id")
    let feed = Task.detached { await SessionLauncher.feed(observer, from: terminal) }

    while await terminal.interests.isEmpty { await Task.yield() }
    await terminal.print("id: 42\n")
    await terminal.end()
    await feed.value

    #expect(await terminal.interests == [.state])
    #expect(await observer.read.isEmpty)
  }

  @Test("An observer that found what it read for stops being handed the output")
  func observerLetsGoOnceItHasEnough() async {
    let terminal = InterestTerminal()
    let observer = ReadingObserver(wanted: "session id: 42")
    let feed = Task.detached { await SessionLauncher.feed(observer, from: terminal) }

    while await terminal.interests.isEmpty { await Task.yield() }
    await terminal.print("booting\r\n")
    await terminal.print("session id: 42\r\n")
    // Once it has enough it waits for the end on the state alone.
    while await terminal.interests.count < 2 { await Task.yield() }
    #expect(await terminal.interests == [.everything, .state])
    while await terminal.byteReaders > 0 { await Task.yield() }
    await terminal.print("working hard\r\n")
    await terminal.end()
    await feed.value

    #expect(await !observer.read.contains("working hard"))
  }

  @MainActor
  @Test("The last output of a session is asked of its terminal")
  func lastOutputIsTheTerminals() async {
    let session = WorkSession(
      name: "Tidy", agent: SessionAgentConfiguration(providerID: "stub"), status: .closed,
      repositories: [RepositoryContext(path: "/workspace")])
    let supervisor = OneTerminalSupervisor()
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: OneSessionStore(session), agents: NoAgents(),
      viewportTimeout: .zero)

    #expect(await launcher.lastOutput(of: session.id) == nil)
    let plan = AgentLaunchPlan(
      providerID: AgentProviderID("stub"), executablePath: "/usr/bin/true", arguments: [],
      environment: [:], workingDirectoryPath: "/workspace", promptDelivery: .argument)
    #expect(await launcher.launch(session: session, plan: plan))
    let terminal = await supervisor.started
    #expect(terminal != nil)
    #expect(await launcher.lastOutput(of: session.id) == terminal?.lastOutput)
  }
}

private actor OneTerminalSupervisor: TerminalSupervisor {
  private(set) var started: InterestTerminal?

  func start(_ spec: TerminalSpec, for id: TerminalID) -> any TerminalSession {
    let terminal = InterestTerminal()
    started = terminal
    return terminal
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { started }
  func stop(id: TerminalID, gracePeriod: Duration) {}
  func stopAll(gracePeriod: Duration) {}
}

private actor OneSessionStore: SessionRepository {
  private var stored: WorkSession

  init(_ session: WorkSession) {
    stored = session
  }

  func sessions() -> [WorkSession] { [stored] }
  func session(id: SessionID) -> WorkSession? { id == stored.id ? stored : nil }
  func save(_ session: WorkSession) { stored = session }
}

private struct NoAgents: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { nil }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}
