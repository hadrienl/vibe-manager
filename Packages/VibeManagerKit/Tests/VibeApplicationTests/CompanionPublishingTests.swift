import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Everything handed to the companion, in order, and a stream to wait for it on.
private actor FakeCompanionPublisher: CompanionPublishing {
  enum Call: Equatable {
    case publish(CompanionSnapshot)
    case acknowledge(String, Date)
  }

  private(set) var calls: [Call] = []
  private let continuation: AsyncStream<Call>.Continuation
  nonisolated let stream: AsyncStream<Call>

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func publish(_ snapshot: CompanionSnapshot) {
    calls.append(.publish(snapshot))
    continuation.yield(.publish(snapshot))
  }

  func acknowledge(_ test: CompanionTest, receivedAt: Date) {
    calls.append(.acknowledge(test.nonce, receivedAt))
    continuation.yield(.acknowledge(test.nonce, receivedAt))
  }
}

/// A sleep that lasts until the test lets it end, so that a burst is a burst whatever the machine.
private actor SleepGate {
  private var sleepers: [CheckedContinuation<Void, Never>] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func sleep() async {
    await withCheckedContinuation { continuation in
      sleepers.append(continuation)
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  var count: Int { sleepers.count }

  /// Returns once someone sleeps.
  func waitForSleeper() async {
    if !sleepers.isEmpty { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func wake() {
    for sleeper in sleepers { sleeper.resume() }
    sleepers = []
  }
}

/// The receiving side's fakes write in one log, so the order of what they were told shows.
@MainActor
private final class ReceptionLog: CompanionPublishing, CompanionTestAlerting {
  var events: [String] = []

  func publish(_ snapshot: CompanionSnapshot) async {
    events.append("publish")
  }

  func acknowledge(_ test: CompanionTest, receivedAt: Date) async {
    events.append("acknowledge \(test.nonce) \(receivedAt.timeIntervalSince1970)")
  }

  func present(_ test: CompanionTest, receivedAt: Date) {
    events.append("present \(test.nonce) from \(test.deviceName)")
  }
}

private func session(
  _ name: String, status: SessionStatus, agent: String? = "claude-code", rank: Int = 0
) -> WorkSession {
  WorkSession(
    name: name, agent: agent.map { SessionAgentConfiguration(providerID: $0) }, status: status,
    rank: rank)
}

private func snapshot(_ titles: String...) -> CompanionSnapshot {
  CompanionSnapshot(
    sessions: titles.map {
      CompanionSnapshot.Session(id: SessionID(), title: $0, agent: "Codex", state: .working)
    })
}

@Test("Only the sessions whose agent runs are published, in the sidebar's order, with their state")
func snapshotOfActiveSessions() {
  let asking = session("Asking", status: .active, rank: 2)
  let working = session("Working", status: .active, agent: "codex", rank: 1)
  let idle = session("Idle", status: .active, agent: nil, rank: 3)
  let closed = session("Closed", status: .closed)
  let archived = session("Archived", status: .archived)
  let states: [SessionID: AgentActivityState] = [
    asking.id: AgentActivityState(activity: .awaitingUser(.approval)),
    working.id: AgentActivityState(activity: .working),
    closed.id: AgentActivityState(activity: .working),
  ]
  let names = ["claude-code": "Claude Code", "codex": "Codex"]

  let snapshot = CompanionSnapshot.make(
    sessions: [asking, closed, idle, working, archived], activity: { states[$0] },
    agentName: { names[$0] ?? $0 })

  #expect(
    snapshot.sessions == [
      CompanionSnapshot.Session(id: working.id, title: "Working", agent: "Codex", state: .working),
      CompanionSnapshot.Session(
        id: asking.id, title: "Asking", agent: "Claude Code", state: .needsAttention),
      CompanionSnapshot.Session(id: idle.id, title: "Idle", agent: "", state: .waiting),
    ])
}

@Test("A waiting session carries its first request, for the phone's notification (#401)")
func waitingSessionCarriesRequest() {
  let asking = session("Asking", status: .active, rank: 1)
  var state = AgentActivityState(activity: .awaitingUser(.approval))
  state.requests = [
    AgentRequest(
      id: AgentRequestID(sessionID: asking.id, key: "K1"), receivedAt: Date(), kind: .approval,
      content: .permission(
        AgentToolPermission(
          tool: .shell, toolName: "Bash", subject: "git push", purpose: "Publish the branch")),
      reference: AgentToolReference(tool: "Bash"), isShown: true),
    AgentRequest(
      id: AgentRequestID(sessionID: asking.id, key: "K2"), receivedAt: Date(), kind: .approval,
      content: .questions([]), reference: AgentToolReference(tool: "AskUserQuestion"),
      isShown: false),
  ]

  let snapshot = CompanionSnapshot.make(
    sessions: [asking], activity: { _ in state }, agentName: { $0 })

  #expect(
    snapshot.sessions.first?.request
      == CompanionSnapshot.Request(
        id: "K1", kind: .permission, title: "Publish the branch", subject: "git push"))
}

@Test("A burst of changes leaves as one snapshot, the last")
@MainActor
func burstIsCoalesced() async {
  let publisher = FakeCompanionPublisher()
  let gate = SleepGate()
  let publish = PublishCompanionSnapshot(publisher: publisher, sleep: { _ in await gate.sleep() })
  let last = snapshot("C")

  publish.update(snapshot("A"))
  publish.update(snapshot("B"))
  publish.update(last)
  await gate.waitForSleeper()
  #expect(await gate.count == 1)
  await gate.wake()

  var published = publisher.stream.makeAsyncIterator()
  #expect(await published.next() == .publish(last))
  #expect(await publisher.calls == [.publish(last)])
}

@Test("A snapshot unchanged since the last one sent is not sent again")
@MainActor
func unchangedSnapshotIsNotSent() async {
  let publisher = FakeCompanionPublisher()
  let gate = SleepGate()
  let publish = PublishCompanionSnapshot(publisher: publisher, sleep: { _ in await gate.sleep() })
  let first = snapshot("A")

  publish.update(first)
  await gate.waitForSleeper()
  await gate.wake()
  var published = publisher.stream.makeAsyncIterator()
  #expect(await published.next() == .publish(first))

  publish.update(first)
  #expect(!publish.isWaiting)

  // A burst that ends where it started sends nothing either.
  publish.update(snapshot("B"))
  publish.update(first)
  await gate.waitForSleeper()
  await gate.wake()
  while publish.isWaiting { await Task.yield() }
  let next = snapshot("C")
  publish.update(next)
  await gate.waitForSleeper()
  await gate.wake()
  #expect(await published.next() == .publish(next))
  #expect(await publisher.calls == [.publish(first), .publish(next)])
}

@Test("A test is acknowledged before its alert is shown, at the instant it arrived")
@MainActor
func testIsAcknowledgedFirst() async {
  let log = ReceptionLog()
  let arrival = Date(timeIntervalSince1970: 1_800_000_002)
  let receive = ReceiveCompanionTest(publisher: log, alerts: log, clock: { arrival })
  let test = CompanionTest(
    nonce: "7F3A", deviceName: "iPhone", sentAt: Date(timeIntervalSince1970: 1_800_000_000))

  await receive(test)

  #expect(log.events == ["acknowledge 7F3A 1800000002.0", "present 7F3A from iPhone"])
}
