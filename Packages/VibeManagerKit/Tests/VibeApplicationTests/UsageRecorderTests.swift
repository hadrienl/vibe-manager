import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private final class MovingClock: SessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var time: Date

  init(_ time: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
    self.time = time
  }

  func now() -> Date {
    lock.withLock { time }
  }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { time = time.addingTimeInterval(seconds) }
  }
}

@Suite("Recording agent runs")
struct UsageRecorderTests {
  private func runs(_ ledger: InMemoryUsageLedger) async -> [UsageRun] {
    UsageLedgerFold.runs(from: await ledger.events())
  }

  @Test("A start and an end make one closed run")
  func startAndEnd() async {
    let ledger = InMemoryUsageLedger()
    let clock = MovingClock()
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    await recorder.settleLaunch(running: [], closedAt: [:])
    let session = SessionID()

    await recorder.started(
      session, providerID: "claude-code", modelID: "opus",
      context: UsageRunContext(kind: .resume, afterRelaunch: true))
    clock.advance(600)
    await recorder.ended(session, exit: .exited)
    await recorder.ended(session, exit: .stopped)

    let recorded = await runs(ledger)
    #expect(recorded.count == 1)
    #expect(recorded.first?.kind == .resume)
    #expect(recorded.first?.afterRelaunch == true)
    #expect(recorded.first?.exit == .exited)
    #expect(recorded.first?.runningTime(in: nil, now: clock.now()) == 600)
    #expect(await ledger.heartbeat() == nil)
  }

  @Test("A run the application died with is closed at its last heartbeat")
  func crashClosesAtHeartbeat() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let open = UsageRun(
      sessionID: SessionID(), providerID: "codex", modelID: nil, kind: .start, startedAt: start)
    let orphan = UsageRun(
      sessionID: SessionID(), providerID: "codex", modelID: nil, kind: .start, startedAt: start)
    let ledger = InMemoryUsageLedger(
      events: [.start(open), .start(orphan)],
      heartbeat: UsageHeartbeat(at: start.addingTimeInterval(120), runIDs: [open.id]))
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(),
      clock: MovingClock(start.addingTimeInterval(86_400)))

    await recorder.prepare()
    // Reading writes nothing: only the settlement closes what the previous launch left.
    #expect(await runs(ledger).allSatisfy(\.isOpen))
    await recorder.settleLaunch(running: [], closedAt: [:])

    let recorded = await runs(ledger)
    #expect(recorded.first { $0.id == open.id }?.endedAt == start.addingTimeInterval(120))
    // Never named by a heartbeat: nothing says it ran past its start.
    #expect(recorded.first { $0.id == orphan.id }?.endedAt == start)
    #expect(recorded.allSatisfy { $0.exit == .interrupted })
  }

  @Test("A run left in the terminal host goes on when adopted, and ends when its session closed")
  func detachedRuns() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let first = UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    let kept = SessionID()
    let ended = SessionID()
    for id in [kept, ended] {
      await first.started(
        id, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    }
    clock.advance(60)
    await first.detached(kept)
    await first.detached(ended)
    let closedAt = clock.now().addingTimeInterval(1_800)
    clock.advance(3_600)

    let second = UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    await second.prepare()
    #expect(await runs(ledger).allSatisfy(\.isOpen))
    await second.settleLaunch(running: [kept], closedAt: [ended: closedAt])

    let recorded = await runs(ledger)
    #expect(recorded.first { $0.sessionID == kept }?.isOpen == true)
    // Taken back in the journal too: a crash now closes it at a heartbeat, not at the hand-off.
    #expect(recorded.first { $0.sessionID == kept }?.detachedAt == nil)
    let finished = recorded.first { $0.sessionID == ended }
    #expect(finished?.endedAt == closedAt)
    #expect(finished?.exit == .endedWhileAway)
  }

  @Test("Nothing is recorded while tracking is off, and turning it off ends what runs")
  func trackingOff() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let tracking = InMemoryUsageTrackingStore()
    let recorder = UsageRecorder(ledger: ledger, tracking: tracking, clock: clock)
    let running = SessionID()
    await recorder.started(
      running, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    clock.advance(60)

    await recorder.setTracking(false)
    await recorder.started(
      SessionID(), providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))

    let recorded = await runs(ledger)
    #expect(recorded.count == 1)
    #expect(recorded.first?.exit == .stopped)
    #expect(await tracking.intervals().isTracking == false)
    #expect(await tracking.intervals().last?.to == clock.now().storageRounded)
  }

  @Test("Clearing forgets everything and counts what runs from now")
  func clearing() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let tracking = InMemoryUsageTrackingStore()
    let recorder = UsageRecorder(ledger: ledger, tracking: tracking, clock: clock)
    let session = SessionID()
    await recorder.started(
      session, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    clock.advance(3_600)

    await recorder.clear()

    let recorded = await runs(ledger)
    #expect(recorded.count == 1)
    #expect(recorded.first?.startedAt == clock.now().storageRounded)
    #expect(await tracking.intervals() == [UsageTrackingInterval(from: clock.now().storageRounded)])
  }

  @Test("Sleep between a start and an end is not counted")
  func sleep() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    let session = SessionID()
    await recorder.started(
      session, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    clock.advance(600)
    await recorder.systemWillSleep()
    clock.advance(7_200)
    await recorder.systemDidWake()
    clock.advance(600)
    await recorder.ended(session, exit: .exited)

    let recorded = await runs(ledger)
    #expect(recorded.first?.runningTime(in: nil, now: clock.now()) == 1_200)
  }
}

@Suite("Recording agent runs, when things go wrong")
struct UsageRecorderEdgeTests {
  @Test("A copy that only reads leaves the other copy's runs alone")
  func sealedCopyWritesNothing() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let owner = UsageRecorder(ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    let session = SessionID()
    await owner.started(
      session, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    let before = await ledger.events()

    let reader = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    await reader.seal()
    await reader.settleLaunch(running: [], closedAt: [:])
    await reader.started(
      SessionID(), providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    await reader.clear()

    #expect(await ledger.events() == before)
    #expect(await ledger.heartbeat() != nil)
  }

  @Test("A recorder sealed by a launch that is tried again records once it is settled")
  func unsealedAfterRetry() async {
    let ledger = InMemoryUsageLedger()
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: MovingClock())
    await recorder.seal()
    await recorder.settleLaunch(running: [], closedAt: [:])

    await recorder.unseal()
    await recorder.settleLaunch(running: [], closedAt: [:])
    await recorder.started(
      SessionID(), providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))

    #expect(UsageLedgerFold.runs(from: await ledger.events()).count == 1)
  }

  @Test("A session started while the launch is settled keeps its new run")
  func startDuringSettlement() async {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let first = UsageRun(
      sessionID: SessionID(), providerID: "codex", modelID: nil, kind: .start, startedAt: start)
    let second = UsageRun(
      sessionID: SessionID(), providerID: "codex", modelID: nil, kind: .start, startedAt: start)
    let ledger = HookedUsageLedger(events: [
      .start(first), .detach(runID: first.id, at: start),
      .start(second), .detach(runID: second.id, at: start),
    ])
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(),
      clock: MovingClock(start.addingTimeInterval(3_600)))
    // Whichever run is settled first, the other session is started again during that write.
    await ledger.onFirstEnd { runID in
      let other = runID == first.id ? second.sessionID : first.sessionID
      await recorder.started(
        other, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .resume))
    }

    await recorder.settleLaunch(running: [], closedAt: [:])

    let open = await recorder.openRuns()
    #expect(open.count == 1)
    #expect(open.first?.kind == .resume)
    let ends = await ledger.events().filter {
      guard case .end = $0 else { return false }
      return true
    }
    // Each detached run ended once: the restarted one by its restart, the other by the settlement.
    #expect(ends.count == 2)
  }

  @Test("A sleep whose wake was lost takes nothing from the runs after it")
  func lostWake() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let first = UsageRun(
      sessionID: SessionID(), providerID: "codex", modelID: nil, kind: .start,
      startedAt: start.addingTimeInterval(3_600))
    let events: [UsageLedgerEvent] = [
      .suspend(at: start),
      .start(first),
      .end(runID: first.id, at: start.addingTimeInterval(7_200), exit: .exited),
      .resume(at: start.addingTimeInterval(7_300)),
    ]
    let run = UsageLedgerFold.runs(from: events).first
    #expect(run?.runningTime(in: nil, now: start) == 3_600)
  }

  @Test("The wake is written even when every run ended during the sleep")
  func wakeAlwaysFollowsSleep() async {
    let clock = MovingClock()
    let ledger = InMemoryUsageLedger()
    let recorder = UsageRecorder(
      ledger: ledger, tracking: InMemoryUsageTrackingStore(), clock: clock)
    let session = SessionID()
    await recorder.started(
      session, providerID: "codex", modelID: nil, context: UsageRunContext(kind: .start))
    await recorder.systemWillSleep()
    await recorder.ended(session, exit: .exited)
    await recorder.systemDidWake()

    let events = await ledger.events()
    #expect(
      events.contains {
        guard case .resume = $0 else { return false }
        return true
      })
  }
}

@Suite("Reading usage")
struct UsageServiceTests {
  private struct StubReader: TokenUsageReading {
    let sessionID: SessionID
    let when: Date
    /// Adds to what the snapshot already holds, as a transcript that keeps growing does.
    var growing = false

    func refresh(
      _ sessions: [WorkSession], from snapshot: TokenUsageSnapshot,
      isTracked: @escaping @Sendable (Date) -> Bool
    ) async -> TokenUsageSnapshot {
      var file =
        (growing ? snapshot.files["/rollout.jsonl"] : nil)
        ?? TokenUsageFile(sessionID: sessionID, providerID: "codex")
      if isTracked(when) {
        file.add(
          TokenCounts(input: 5, output: 1), model: "gpt",
          day: LocalDay(when, calendar: .current), fallback: false)
      }
      return TokenUsageSnapshot(files: ["/rollout.jsonl": file])
    }
  }

  @Test("Tokens from a time tracking was off are not read")
  func trackingOffIsNotRead() async {
    let clock = MovingClock()
    let session = SessionID()
    let tracking = InMemoryUsageTrackingStore(intervals: [
      UsageTrackingInterval(from: .distantPast, to: clock.now().addingTimeInterval(-7_200)),
      UsageTrackingInterval(from: clock.now().addingTimeInterval(-60)),
    ])
    let ledger = InMemoryUsageLedger()
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking, clock: clock), ledger: ledger,
      tracking: tracking, tokenStore: InMemoryTokenUsageStore(),
      reader: StubReader(sessionID: session, when: clock.now().addingTimeInterval(-3_600)),
      clock: clock)

    await service.refreshTokens(for: [])

    let report = await service.report(period: .allTime, grouping: .session)
    #expect(report.total.hasReportedTokens == false)
  }

  @Test("A copy that only reads saves no tokens and clears nothing")
  func readOnlyCopy() async {
    let clock = MovingClock()
    let session = SessionID()
    let tracking = InMemoryUsageTrackingStore()
    let ledger = InMemoryUsageLedger()
    let store = InMemoryTokenUsageStore()
    let owner = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking, clock: clock), ledger: ledger,
      tracking: tracking, tokenStore: store,
      reader: StubReader(sessionID: session, when: clock.now().addingTimeInterval(-3_600)),
      clock: clock)
    await owner.refreshTokens(for: [])
    let saved = await store.load()

    let recorder = UsageRecorder(ledger: ledger, tracking: tracking, clock: clock)
    await recorder.seal()
    let copy = UsageService(
      recorder: recorder, ledger: ledger, tracking: tracking, tokenStore: store,
      reader: StubReader(sessionID: SessionID(), when: clock.now().addingTimeInterval(-60)),
      clock: clock)
    #expect(await copy.refreshTokens(for: []) == false)
    await copy.clear()

    #expect(await store.load() == saved)
  }

  @Test("A reading asked for during a clear does not put the tokens back")
  func readingDuringClear() async {
    let clock = MovingClock()
    let session = SessionID()
    let tracking = InMemoryUsageTrackingStore()
    let ledger = InMemoryUsageLedger()
    let store = HookedTokenUsageStore()
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking, clock: clock), ledger: ledger,
      tracking: tracking, tokenStore: store,
      reader: StubReader(sessionID: session, when: clock.now(), growing: true), clock: clock)
    await service.refreshTokens(for: [])
    await store.onClear { await service.refreshTokens(for: []) }

    await service.clear()

    #expect(await service.sessionReport(session).hasReportedTokens == false)
    #expect(await store.load().buckets.isEmpty)
  }

  @Test("Clearing empties the token totals")
  func clearing() async {
    let clock = MovingClock()
    let session = SessionID()
    let tracking = InMemoryUsageTrackingStore()
    let ledger = InMemoryUsageLedger()
    let store = InMemoryTokenUsageStore()
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking, clock: clock), ledger: ledger,
      tracking: tracking, tokenStore: store,
      reader: StubReader(sessionID: session, when: clock.now().addingTimeInterval(-3_600)),
      clock: clock)
    await service.refreshTokens(for: [])
    #expect(await service.sessionReport(session).tokens.input == 5)

    await service.clear()
    await service.refreshTokens(for: [])

    // Read again after the clear, but from before it: it does not come back.
    #expect(await service.sessionReport(session).hasReportedTokens == false)
    #expect(await store.load().buckets.isEmpty)
  }
}

/// A journal that runs something of the test's in the middle of the first `end` it is given.
private actor HookedUsageLedger: UsageLedger {
  private let inner: InMemoryUsageLedger
  private var hook: (@Sendable (UUID) async -> Void)?

  init(events: [UsageLedgerEvent]) {
    inner = InMemoryUsageLedger(events: events)
  }

  func onFirstEnd(_ hook: @escaping @Sendable (UUID) async -> Void) {
    self.hook = hook
  }

  func append(_ event: UsageLedgerEvent) async {
    await inner.append(event)
    if case .end(let runID, _, _) = event, let hook {
      self.hook = nil
      await hook(runID)
    }
  }

  func events() async -> [UsageLedgerEvent] { await inner.events() }
  func writeHeartbeat(_ heartbeat: UsageHeartbeat?) async { await inner.writeHeartbeat(heartbeat) }
  func heartbeat() async -> UsageHeartbeat? { await inner.heartbeat() }
  func clear() async { await inner.clear() }
}

/// A token store that runs something of the test's in the middle of being cleared.
private actor HookedTokenUsageStore: TokenUsageStore {
  private let inner = InMemoryTokenUsageStore()
  private var hook: (@Sendable () async -> Void)?

  func onClear(_ hook: @escaping @Sendable () async -> Void) {
    self.hook = hook
  }

  func load() async -> TokenUsageSnapshot { await inner.load() }
  func save(_ snapshot: TokenUsageSnapshot) async { await inner.save(snapshot) }

  func clear() async {
    await inner.clear()
    if let hook {
      self.hook = nil
      await hook()
    }
  }
}
