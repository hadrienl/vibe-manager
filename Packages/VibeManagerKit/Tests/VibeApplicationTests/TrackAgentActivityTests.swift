import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// A log whose lines the test writes, and reads back as the tracker would.
actor ScriptedActivityLogs: AgentActivityLogStore {
  private var continuations:
    [SessionID: AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>.Continuation] = [:]
  private(set) var requestedPositions: [SessionID: AgentActivityLogPosition?] = [:]
  private(set) var removed: [SessionID] = []
  private var offsets: [SessionID: UInt64] = [:]

  func prepareLog(for id: SessionID) -> URL {
    URL(fileURLWithPath: "/tmp/\(id).log")
  }

  func existingLog(for id: SessionID) -> URL? {
    URL(fileURLWithPath: "/tmp/\(id).log")
  }

  func events(for id: SessionID, from position: AgentActivityLogPosition?)
    -> AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
  {
    requestedPositions[id] = position
    offsets[id] = position?.offset ?? 0
    let (stream, continuation) = AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
      .makeStream()
    continuations[id] = continuation
    return stream
  }

  func removeLog(for id: SessionID) {
    removed.append(id)
  }

  func write(_ name: String, at date: Date, for id: SessionID, payload: String? = nil) {
    let offset = (offsets[id] ?? 0) + 10
    offsets[id] = offset
    continuations[id]?.yield(
      (
        AgentActivityEvent(name: name, date: date, payload: payload.map { Data($0.utf8) }),
        AgentActivityLogPosition(fileIdentifier: 7, offset: offset)
      ))
  }

  func isFollowing(_ id: SessionID) -> Bool {
    continuations[id] != nil
  }
}

actor MemoryActivityStore: AgentActivityStateStore {
  var stored: [SessionID: PersistedAgentActivity]

  init(_ stored: [SessionID: PersistedAgentActivity] = [:]) {
    self.stored = stored
  }

  func read() -> [SessionID: PersistedAgentActivity] {
    stored
  }

  func write(_ activities: [SessionID: PersistedAgentActivity]) {
    stored = activities
  }
}

final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  var now: Date {
    lock.withLock { value }
  }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(seconds) }
  }
}

/// Maps the event names one to one: the decoders have tests of their own.
private struct NamedDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = [[0x0D]]

  func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "start": return .channelConfirmed
    case "prompt": return .promptSubmitted(byUser: true)
    case "ask": return .questionAsked(.approval)
    case "stop": return .turnEnded
    default: return nil
    }
  }
}

/// Opens a source on every `start`, and counts how many are open at once.
private final class SourceCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var open = 0
  private(set) var opened = 0
  var continuations: [AsyncStream<AgentSignal>.Continuation] = []

  var openCount: Int { lock.withLock { open } }
  var openedCount: Int { lock.withLock { opened } }

  func stream() -> AsyncStream<AgentSignal> {
    AsyncStream { continuation in
      lock.withLock {
        open += 1
        opened += 1
        continuations.append(continuation)
      }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { self.open -= 1 }
      }
    }
  }

  func interrupt() {
    let last = lock.withLock { continuations.last }
    last?.yield(.interrupted)
  }
}

private struct SourceDecoder: AgentSignalDecoding {
  let counter: SourceCounter
  let approvalAnswerKeys: Set<[UInt8]> = []

  func signal(for event: AgentActivityEvent) -> AgentSignal? {
    NamedDecoder().signal(for: event)
  }

  func additionalSignals(after event: AgentActivityEvent) -> AsyncStream<AgentSignal>? {
    event.name == "start" ? counter.stream() : nil
  }
}

private let t0 = Date(timeIntervalSince1970: 2_000_000)

/// The tracker subscribes to a log on a task of its own: lines written before that are the test's
/// mistake, not the tracker's.
func following(_ logs: ScriptedActivityLogs, _ id: SessionID) async -> Bool {
  for _ in 0..<200 {
    if await logs.isFollowing(id) { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}

func makeTracker(
  logs: ScriptedActivityLogs, store: MemoryActivityStore, clock: TestClock
) -> TrackAgentActivity {
  TrackAgentActivity(
    logs: logs, store: store, now: { clock.now },
    // Timers never fire on their own: the tests tick.
    sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
    persistenceDelay: .seconds(3600))
}

/// Waits until the tracker reports `predicate`, or fails after a second.
func eventually(
  _ tracker: TrackAgentActivity, _ id: SessionID,
  _ predicate: @Sendable (AgentActivityState?) -> Bool
) async -> Bool {
  for _ in 0..<200 {
    if predicate(await tracker.state(for: id)) { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}

@Suite("Tracking agent activity")
struct TrackAgentActivityTests {
  @Test("An answer finished out of sight is unread until the session is shown")
  func unreadUntilShown() async {
    let logs = ScriptedActivityLogs()
    let clock = TestClock(t0)
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: clock)
    let id = SessionID()

    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("start", at: t0, for: id)
    await logs.write("prompt", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .working })
    await logs.write("stop", at: t0.addingTimeInterval(4), for: id)
    #expect(await eventually(tracker, id) { $0?.unreadSince != nil })

    await tracker.setVisibleSession(id)
    #expect(await tracker.state(for: id)?.unreadSince == nil)
  }

  @Test("An answer finished while the session is shown is not unread")
  func seenAsItArrives() async {
    let logs = ScriptedActivityLogs()
    let clock = TestClock(t0)
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: clock)
    let id = SessionID()

    await tracker.setVisibleSession(id)
    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("prompt", at: t0, for: id)
    await logs.write("stop", at: t0.addingTimeInterval(2), for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .idle && $0?.source == .structured })
    #expect(await tracker.state(for: id)?.unreadSince == nil)
  }

  @Test("What an adopted agent did while the application was closed is unread, unless shown")
  func adoptionReplaysUnseen() async {
    let id = SessionID()
    let position = AgentActivityLogPosition(fileIdentifier: 7, offset: 40)
    let store = MemoryActivityStore([
      id: PersistedAgentActivity(activity: .working, log: position, isConfirmed: true)
    ])
    let logs = ScriptedActivityLogs()
    let clock = TestClock(t0.addingTimeInterval(600))
    let tracker = makeTracker(logs: logs, store: store, clock: clock)

    await tracker.processAdopted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    #expect(await tracker.state(for: id)?.activity == .working)
    #expect(await tracker.state(for: id)?.source == .structured)
    #expect(await logs.requestedPositions[id] == position)

    // Written ten minutes ago, while nobody was looking.
    await logs.write("stop", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.unreadSince == t0 })
  }

  @Test("An adopted session in front of the user reads what it replays")
  func adoptionWhileShown() async {
    let id = SessionID()
    let store = MemoryActivityStore([
      id: PersistedAgentActivity(
        activity: .working, log: AgentActivityLogPosition(fileIdentifier: 7, offset: 40),
        isConfirmed: true)
    ])
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: store, clock: TestClock(t0))
    await tracker.setVisibleSession(id)
    await tracker.processAdopted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("stop", at: t0.addingTimeInterval(-600), for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .idle })
    #expect(await tracker.state(for: id)?.unreadSince == nil)
  }

  @Test("Hooks that had never spoken are not believed after an adoption either")
  func adoptionOfUnconfirmedHooks() async {
    let id = SessionID()
    let store = MemoryActivityStore([
      id: PersistedAgentActivity(
        activity: .working, log: AgentActivityLogPosition(fileIdentifier: 7, offset: 0),
        isConfirmed: false)
    ])
    let clock = TestClock(t0)
    let tracker = makeTracker(logs: ScriptedActivityLogs(), store: store, clock: clock)
    await tracker.processAdopted(id, decoder: NamedDecoder())
    let state = await tracker.state(for: id)
    #expect(state?.activity == .idle)
    #expect(state?.source == .unconfirmed(since: t0))
    // Its output counts, as at a launch.
    await tracker.output(id)
    #expect(await tracker.state(for: id)?.activity == .working)
  }

  @Test("A keystroke that changes nothing on screen is neither published nor written")
  func keystrokesAreQuiet() async {
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t0))
    let id = SessionID()
    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("prompt", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .working })
    let updates = await tracker.updates()
    for key: UInt8 in [0x61, 0x62, 0x63] { await tracker.userInput(id, [key]) }
    await tracker.setVisibleSession(nil)
    await logs.write("stop", at: t0, for: id)
    var received: [AgentActivityUpdate] = []
    for await update in updates {
      received.append(update)
      if update.state?.activity == .idle { break }
    }
    #expect(received.count == 1)
  }

  @Test("A relaunched agent keeps what the last one left unread")
  func unreadSurvivesRestart() async {
    let id = SessionID()
    let store = MemoryActivityStore([
      id: PersistedAgentActivity(activity: .working, unreadSince: t0)
    ])
    let tracker = makeTracker(logs: ScriptedActivityLogs(), store: store, clock: TestClock(t0))

    await tracker.load()
    await tracker.processStarted(id, decoder: NamedDecoder())
    let state = await tracker.state(for: id)
    #expect(state?.unreadSince == t0)
    // The question or the work of the previous process is not this one's.
    #expect(state?.activity == .idle)
  }

  @Test("Flushing writes the unread marks and how far each log was read")
  func flushPersists() async {
    let logs = ScriptedActivityLogs()
    let store = MemoryActivityStore()
    let tracker = makeTracker(logs: logs, store: store, clock: TestClock(t0))
    let id = SessionID()

    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("stop", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.unreadSince != nil })
    await tracker.flush()
    let stored = await store.stored[id]
    #expect(stored?.unreadSince == t0)
    #expect(stored?.log == AgentActivityLogPosition(fileIdentifier: 7, offset: 10))
  }

  @Test("A forgotten session loses its state and its log")
  func forget() async {
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t0))
    let id = SessionID()
    let updates = await tracker.updates()

    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await tracker.forget(id)
    #expect(await tracker.state(for: id) == nil)
    #expect(await logs.removed == [id])

    var sawRemoval = false
    for await update in updates {
      if update.sessionID == id, update.state == nil {
        sawRemoval = true
        break
      }
    }
    #expect(sawRemoval)
  }

  @Test("Without hooks, output and silence drive the agent, and a tick ends the work")
  func inferredWithTicks() async {
    let clock = TestClock(t0)
    let tracker = makeTracker(
      logs: ScriptedActivityLogs(), store: MemoryActivityStore(), clock: clock)
    let id = SessionID()

    await tracker.processStarted(id, decoder: nil)
    await tracker.output(id)
    #expect(await tracker.state(for: id)?.activity == .working)
    clock.advance(3)
    await tracker.tick()
    #expect(await tracker.state(for: id)?.activity == .idle)
  }

  @Test("A keystroke that answers a permission is read with the agent's own keys")
  func answerKeys() async {
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t0))
    let id = SessionID()

    await tracker.processStarted(id, decoder: NamedDecoder())
    #expect(await following(logs, id))
    await logs.write("ask", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .awaitingUser(.approval) })
    await tracker.userInput(id, [0x0D])
    #expect(await tracker.state(for: id)?.activity == .working)
  }

  @Test("A session started again opens its source again, in place of the previous one")
  func oneSourceAtATime() async {
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t0))
    let counter = SourceCounter()
    let id = SessionID()
    await tracker.processStarted(id, decoder: SourceDecoder(counter: counter))
    #expect(await following(logs, id))
    await logs.write("start", at: t0, for: id)
    await logs.write("prompt", at: t0, for: id)
    #expect(await eventually(tracker, id) { $0?.activity == .working })
    await logs.write("start", at: t0, for: id)
    #expect(await eventuallyTrue { counter.openedCount == 2 })
    #expect(await eventuallyTrue { counter.openCount == 1 })
    counter.interrupt()
    #expect(await eventually(tracker, id) { $0?.activity == .idle })
  }

  @Test("An adopted session opens again the source its last launch had opened")
  func adoptionReopensSource() async {
    let id = SessionID()
    let store = MemoryActivityStore([
      id: PersistedAgentActivity(
        activity: .working, log: AgentActivityLogPosition(fileIdentifier: 7, offset: 40),
        isConfirmed: true,
        sourceEvent: PersistedAgentActivityEvent(AgentActivityEvent(name: "start", date: t0)))
    ])
    let logs = ScriptedActivityLogs()
    let tracker = makeTracker(logs: logs, store: store, clock: TestClock(t0))
    let counter = SourceCounter()
    await tracker.processAdopted(id, decoder: SourceDecoder(counter: counter))
    #expect(await eventuallyTrue { counter.openCount == 1 })
    counter.interrupt()
    #expect(await eventually(tracker, id) { $0?.activity == .idle })
    await tracker.flush()
    #expect(await store.stored[id]?.sourceEvent?.name == "start")
  }
}

private func eventuallyTrue(_ predicate: @Sendable () -> Bool) async -> Bool {
  for _ in 0..<200 {
    if predicate() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}
