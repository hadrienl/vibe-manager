import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Detecting how the previous run ended")
struct DetectPreviousShutdownTests {
  // MARK: - Fixtures

  private static let launch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let lastSeen = Date(timeIntervalSince1970: 1_700_000_600)
  private static let now = Date(timeIntervalSince1970: 1_700_009_999)

  private func session(
    name: String = "Refactor the webhook",
    status: SessionStatus,
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_100)
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Split the signature check out.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept"),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: updatedAt,
      closedAt: status == .active ? nil : updatedAt,
      archivedAt: status == .archived ? updatedAt : nil,
      repositories: [RepositoryContext(path: Fixture.folderPath)]
    )
  }

  private func state(
    phase: SessionRuntimeState.Phase,
    processIdentifier: Int32 = 1_001,
    processStartedAt: Date? = Date(timeIntervalSince1970: 1_699_999_000),
    sessions: [SessionRuntimeRecord]
  ) -> SessionRuntimeState {
    SessionRuntimeState(
      phase: phase,
      processIdentifier: processIdentifier,
      processStartedAt: processStartedAt,
      launchedAt: Self.launch,
      updatedAt: Self.lastSeen,
      stoppedAt: phase == .stopped ? Self.lastSeen : nil,
      sessions: sessions
    )
  }

  private func makeSubject(
    sessions: [WorkSession],
    document: SessionRuntimeState? = nil,
    processes: StubProcesses = StubProcesses()
  ) async -> (DetectPreviousShutdown, MutableRepository, EphemeralSessionRuntimeStateStore) {
    let repository = MutableRepository(sessions: sessions)
    let store = EphemeralSessionRuntimeStateStore(state: document)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: processes,
      clock: FixedClock(Self.now)
    )
    let subject = DetectPreviousShutdown(
      repository: repository,
      recorder: recorder,
      processes: processes,
      clock: FixedClock(Self.now),
      processIdentifier: 4242
    )
    return (subject, repository, store)
  }

  // MARK: - Verdicts

  @Test("No document and nothing stale in the store is nothing to do")
  func nothingToDo() async {
    let subject = session(status: .closed)
    let (detect, repository, _) = await makeSubject(sessions: [subject])

    #expect(await detect() == .nothingToDo)
    #expect(await repository.status(of: subject.id) == .closed)
  }

  @Test("A stopped document with an empty list says nothing")
  func aCleanQuitWithNothingRunningSaysNothing() async {
    let subject = session(status: .closed)
    let (detect, _, _) = await makeSubject(
      sessions: [subject], document: state(phase: .stopped, sessions: []))

    #expect(await detect() == .nothingToDo)
  }

  @Test("A clean quit is restored, in the order it was written in")
  func aCleanQuitIsRestored() async {
    let first = session(name: "First", status: .closed)
    let second = session(name: "Second", status: .closed)
    let (detect, _, _) = await makeSubject(
      sessions: [first, second],
      document: state(
        phase: .stopped,
        sessions: [
          SessionRuntimeRecord(sessionID: first.id),
          SessionRuntimeRecord(sessionID: second.id),
        ]
      )
    )

    #expect(await detect() == .clean(SessionRestoreIntent(sessionIDs: [first.id, second.id])))
  }

  @Test("An unexpected stop closes what the store still calls active, and offers it")
  func anUnexpectedStopReconcilesAndOffers() async {
    let subject = session(status: .active)
    let (detect, repository, _) = await makeSubject(
      sessions: [subject],
      document: state(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    let verdict = await detect()

    #expect(
      verdict
        == .unexpected(
          SessionRestoreIntent(sessionIDs: [subject.id], interruptedAt: Self.lastSeen),
          leftovers: []
        )
    )
    #expect(await repository.status(of: subject.id) == .closed)
    // Dated from the last instant the previous run is known to have been alive, not from the
    // moment the application was reopened.
    #expect(await repository.session(id: subject.id)?.closedAt == Self.lastSeen)
  }

  @Test("A session left active with no document at all is still an unexpected stop")
  func aStaleSessionWithoutADocumentIsUnexpected() async {
    let subject = session(status: .active)
    let (detect, repository, _) = await makeSubject(sessions: [subject])

    #expect(
      await detect()
        == .unexpected(SessionRestoreIntent(sessionIDs: [subject.id]), leftovers: []))
    #expect(await repository.status(of: subject.id) == .closed)
    // Nothing says when the run stopped, so the fallback is the only date there is.
    #expect(await repository.session(id: subject.id)?.closedAt == Self.now)
  }

  @Test("A living instance is not a crash: nothing is reconciled and nothing is claimed")
  func aLivingInstanceIsNotACrash() async {
    let subject = session(status: .active)
    let document = state(
      phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    let (detect, repository, store) = await makeSubject(
      sessions: [subject],
      document: document,
      processes: StubProcesses(
        alive: [1_001], startTimes: [1_001: Date(timeIntervalSince1970: 1_699_999_000)])
    )

    #expect(await detect() == .otherInstance(processIdentifier: 1_001))
    #expect(await repository.status(of: subject.id) == .active)
    #expect(await store.read() == document)
  }

  @Test("The intention is consumed: asked a second time, the detection answers nothing")
  func theIntentionIsConsumedOnce() async {
    let subject = session(status: .closed)
    let (detect, _, _) = await makeSubject(
      sessions: [subject],
      document: state(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    #expect(await detect() == .clean(SessionRestoreIntent(sessionIDs: [subject.id])))
    #expect(await detect() == .nothingToDo)
  }

  @Test("An archived session is not offered, and does not make a count out of nothing")
  func anArchivedSessionIsNotOffered() async {
    let subject = session(status: .archived)
    let (detect, repository, _) = await makeSubject(
      sessions: [subject],
      document: state(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    #expect(await detect() == .nothingToDo)
    #expect(await repository.status(of: subject.id) == .archived)
  }

  @Test("A document this build cannot read is not an error, only an absence")
  func anUnreadableDocumentIsNotAnError() async {
    let subject = session(status: .closed)
    let repository = MutableRepository(sessions: [subject])
    let recorder = SessionRuntimeRecorder(
      store: UnreadableRuntimeStateStore(),
      processIdentifier: 4242,
      probe: StubProcesses(),
      clock: FixedClock(Self.now)
    )
    let detect = DetectPreviousShutdown(
      repository: repository,
      recorder: recorder,
      processes: StubProcesses(),
      clock: FixedClock(Self.now),
      processIdentifier: 4242
    )

    #expect(await detect() == .nothingToDo)
  }

  @Test("A pid worn by another program is a crash, not a second copy")
  func aRecycledPidIsNotASecondCopy() async {
    let subject = session(status: .active)
    let (detect, repository, _) = await makeSubject(
      sessions: [subject],
      document: state(
        phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)]),
      // Alive, but started long after the run that wrote the document: the pid was recycled, and
      // reading it as a living copy would block every restoration from here on.
      processes: StubProcesses(
        alive: [1_001], startTimes: [1_001: Date(timeIntervalSince1970: 1_700_005_000)])
    )

    #expect(
      await detect()
        == .unexpected(
          SessionRestoreIntent(sessionIDs: [subject.id], interruptedAt: Self.lastSeen),
          leftovers: []
        )
    )
    #expect(await repository.status(of: subject.id) == .closed)
  }

  @Test("Our own pid, worn by a run that died, is that run's crash and not this launch")
  func ourOwnPidFromADeadRunIsACrash() async {
    let subject = session(status: .active)
    let (detect, repository, _) = await makeSubject(
      sessions: [subject],
      document: state(
        phase: .running,
        processIdentifier: 4_242,
        sessions: [SessionRuntimeRecord(sessionID: subject.id)]
      ),
      // This process is alive — it is us — but it did not start when the document was written.
      processes: StubProcesses(
        alive: [4_242], startTimes: [4_242: Date(timeIntervalSince1970: 1_700_005_000)])
    )

    guard case .unexpected = await detect() else {
      #expect(Bool(false), "a dead run wearing our pid must not read as this launch")
      return
    }
    #expect(await repository.status(of: subject.id) == .closed)
  }

  @Test("After a crash, the session worked in most recently comes back first")
  func ordersACrashByWhatWasWorkedInLast() async {
    let stale = session(
      name: "Stale", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let recent = session(
      name: "Recent", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_500))
    let (detect, _, _) = await makeSubject(
      sessions: [stale, recent],
      // The records are in the order the sessions were *started*, which is not the order they
      // were worked in.
      document: state(
        phase: .running,
        sessions: [
          SessionRuntimeRecord(sessionID: stale.id),
          SessionRuntimeRecord(sessionID: recent.id),
        ]
      )
    )

    guard case .unexpected(let intent, _) = await detect() else {
      #expect(Bool(false), "expected an unexpected stop")
      return
    }
    #expect(intent.sessionIDs == [recent.id, stale.id])
  }

  @Test("Once another copy is found, this instance writes nothing at all")
  func stopsWritingAfterFindingAnotherCopy() async {
    let subject = session(status: .active)
    let held = state(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    let store = EphemeralSessionRuntimeStateStore(state: held)
    let processes = StubProcesses(
      alive: [1_001], startTimes: [1_001: Date(timeIntervalSince1970: 1_699_999_000)])
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: processes,
      clock: FixedClock(Self.now)
    )
    let detect = DetectPreviousShutdown(
      repository: MutableRepository(sessions: [subject]),
      recorder: recorder,
      processes: processes,
      clock: FixedClock(Self.now),
      processIdentifier: 4242
    )

    #expect(await detect() == .otherInstance(processIdentifier: 1_001))

    // Starting a session here would otherwise overwrite the other copy's pid and its process
    // groups, and its own next launch would find neither.
    await recorder.started(SessionID(), processGroup: 9_001)
    await recorder.markStopped(resuming: [subject.id])
    #expect(await store.read() == held)
  }

  // MARK: - Leftovers

  @Test("A leftover group is stopped only when its identity is confirmed")
  func stopsOnlyConfirmedLeftovers() async {
    let confirmed = session(name: "Confirmed", status: .active)
    let recycled = session(name: "Recycled", status: .active)
    let unknown = session(name: "Unknown", status: .active)
    let startedAt = Date(timeIntervalSince1970: 1_700_000_050)
    let processes = StubProcesses(
      alive: [7_001, 7_002, 7_003],
      startTimes: [7_001: startedAt, 7_002: Date(timeIntervalSince1970: 1_700_008_000)]
    )
    let (detect, _, _) = await makeSubject(
      sessions: [confirmed, recycled, unknown],
      document: state(
        phase: .running,
        sessions: [
          SessionRuntimeRecord(
            sessionID: confirmed.id, processGroup: 7_001, processStartedAt: startedAt),
          SessionRuntimeRecord(
            sessionID: recycled.id, processGroup: 7_002, processStartedAt: startedAt),
          // Nothing was ever recorded about when it started, so nothing establishes what it is.
          SessionRuntimeRecord(sessionID: unknown.id, processGroup: 7_003),
        ]
      ),
      processes: processes
    )

    let verdict = await detect()

    guard case .unexpected(_, let leftovers) = verdict else {
      #expect(Bool(false), "expected an unexpected stop, got \(verdict)")
      return
    }
    #expect(processes.terminated == [7_001])
    #expect(leftovers.map(\.processGroup) == [7_003])
  }
}

// MARK: - Doubles

/// The fixtures' folder and executable, built rather than written out.
///
/// Nothing here is ever opened or run — the folder probe and the launcher are doubles — so what
/// matters is only that the paths are stable and belong to nobody: an absolute system path in a
/// fixture reads as a dependency on the machine the tests happen to run on.
private enum Fixture {
  static let folderPath = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-fixture-folder", isDirectory: true).path
  static let executablePath = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-fixture-agent", isDirectory: false).path
}

private actor MutableRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func status(of id: SessionID) -> SessionStatus? {
    stored.first { $0.id == id }?.status
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? { stored.first { $0.id == id } }

  func save(_ session: WorkSession) {
    guard let index = stored.firstIndex(where: { $0.id == session.id }) else { return }
    stored[index] = session
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    return session
  }
}

/// A document nothing can be read out of — a damaged file, or one from a newer build.
private struct UnreadableRuntimeStateStore: SessionRuntimeStateStore {
  func read() async -> SessionRuntimeState? { nil }

  func write(_: SessionRuntimeState) async {
    // Writes land nowhere: this double exists to answer "nothing readable" to every read.
  }

  func clear() async {
    // Nothing is stored, so there is nothing to clear.
  }
}

/// A system whose processes a test decides on, and which records what it was asked to kill.
///
/// A lock rather than an actor: the probe is synchronous by contract — a leftover check must not
/// be able to suspend in the middle of deciding whether to send a signal.
private final class StubProcesses: ProcessLivenessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private let alive: Set<Int32>
  private let startTimes: [Int32: Date]
  private var killed: [Int32] = []

  init(alive: Set<Int32> = [], startTimes: [Int32: Date] = [:]) {
    self.alive = alive
    self.startTimes = startTimes
  }

  var terminated: [Int32] {
    lock.withLock { killed }
  }

  func isAlive(processIdentifier: Int32) -> Bool {
    alive.contains(processIdentifier)
  }

  func startTime(of processIdentifier: Int32) -> Date? {
    startTimes[processIdentifier]
  }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool {
    lock.withLock { killed.append(processGroup) }
    return true
  }
}

private struct FixedClock: SessionClock {
  let value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date { value }
}
