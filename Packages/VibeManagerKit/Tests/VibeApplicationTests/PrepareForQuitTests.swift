import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Quitting with sessions running")
struct PrepareForQuitTests {
  // MARK: - Fixtures

  private func session(
    name: String,
    status: SessionStatus,
    updatedAt: Date
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
      repositories: [RepositoryContext(path: "/work/app")]
    )
  }

  private func makeSubject(
    sessions: [WorkSession],
    records: [SessionID] = [],
    repository: MutableRepository? = nil
  ) async -> (
    PrepareForQuit, MutableRepository, SpyRuntime, EphemeralSessionRuntimeStateStore, Journal
  ) {
    let journal = Journal()
    let store = EphemeralSessionRuntimeStateStore()
    let repository = repository ?? MutableRepository(sessions: sessions, journal: journal)
    let runtime = SpyRuntime(journal: journal)
    let recorder = SessionRuntimeRecorder(
      store: JournalingRuntimeStateStore(store: store, journal: journal),
      processIdentifier: 4242,
      probe: StubProcesses(),
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )
    for id in records {
      await recorder.started(id, processGroup: 5555)
    }
    await journal.clear()
    let subject = PrepareForQuit(
      repository: repository,
      runtime: runtime,
      recorder: recorder,
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )
    return (subject, repository, runtime, store, journal)
  }

  // MARK: - Tests

  @Test("Every running session is stopped, closed, and left as the intention to resume it")
  func closesEveryActiveSessionAndRecordsTheIntention() async {
    let recent = session(
      name: "Recent", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let older = session(
      name: "Older", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let closed = session(
      name: "Closed", status: .closed, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let archived = session(
      name: "Archived", status: .archived, updatedAt: Date(timeIntervalSince1970: 1_699_500_000))
    let (subject, repository, runtime, store, _) = await makeSubject(
      sessions: [recent, older, closed, archived])

    let shutdown = await subject()

    #expect(shutdown.closed.map(\.name) == ["Recent", "Older"])
    #expect(await repository.status(of: recent.id) == .closed)
    #expect(await repository.status(of: older.id) == .closed)
    // Neither a closed session nor an archived one has a process, so neither is touched.
    #expect(await runtime.detached == [recent.id, older.id])
    #expect(await repository.status(of: archived.id) == .archived)

    let state = await store.read()
    #expect(state?.phase == .stopped)
    #expect(state?.sessions.map(\.sessionID) == [recent.id, older.id])
    // The groups have just been stopped: recorded, they would be looked for — and possibly
    // signalled — at the next launch.
    #expect(state?.sessions.allSatisfy { $0.processGroup == nil } == true)
  }

  @Test("Every process is stopped before any status is written")
  func stopsBeforeWriting() async {
    let first = session(
      name: "First", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let second = session(
      name: "Second", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let (subject, _, _, _, journal) = await makeSubject(sessions: [first, second])

    await subject()

    let entries = await journal.entries
    // The stops are concurrent, so their order between themselves is not a promise; that they all
    // come first is. A session written closed while its agent still runs becomes, if the
    // application dies in between, a closed session with a process nobody owns.
    #expect(Set(entries.prefix(2)) == ["detach:\(first.id)", "detach:\(second.id)"])
    #expect(
      Array(entries.dropFirst(2)) == [
        "close:\(first.id)",
        "close:\(second.id)",
        "runtime:stopped",
      ]
    )
  }

  @Test("The stops are paid concurrently, not one grace period after another")
  func stopsConcurrently() async {
    let first = session(
      name: "First", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let second = session(
      name: "Second", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let journal = Journal()
    let store = EphemeralSessionRuntimeStateStore()
    let runtime = SlowRuntime(journal: journal)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: StubProcesses(),
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )
    let prepare = PrepareForQuit(
      repository: MutableRepository(sessions: [first, second], journal: journal),
      runtime: runtime,
      recorder: recorder,
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )

    await prepare()

    // Both stops were in flight at the same time. Sequentially, a quit would cost one grace
    // period per agent and outrun the deadline the application gives itself — and a quit that
    // never got to write its intention is read as a crash at the next launch.
    #expect(await runtime.highestConcurrency == 2)
  }

  @Test("The intention is written last, so it can only name sessions that really stopped")
  func writesTheIntentionAfterTheClosures() async {
    let subject = session(
      name: "Only", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let (prepare, _, _, _, journal) = await makeSubject(sessions: [subject])

    await prepare()

    #expect(await journal.entries.last == "runtime:stopped")
  }

  @Test("A session that closed itself during the grace period is not an error")
  func aSessionThatClosedItselfIsStillResumed() async {
    let subject = session(
      name: "Finished", status: .closed, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    // Closed in the store, still recorded as running: the agent exited while its terminal was
    // being stopped, which is the one ordering where the two disagree.
    let (prepare, repository, runtime, store, _) = await makeSubject(
      sessions: [subject], records: [subject.id])

    let shutdown = await prepare()

    #expect(shutdown.closed.map(\.id) == [subject.id])
    #expect(await runtime.detached == [subject.id])
    #expect(await repository.status(of: subject.id) == .closed)
    #expect(await store.read()?.sessions.map(\.sessionID) == [subject.id])
  }

  @Test("A read-only instance closes only what it started itself")
  func readOnlyInstanceLeavesTheOtherCopyAlone() async {
    let theirs = session(
      name: "Theirs", status: .active, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let journal = Journal()
    let store = EphemeralSessionRuntimeStateStore()
    let repository = MutableRepository(sessions: [theirs], journal: journal)
    let runtime = SpyRuntime(journal: journal)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: StubProcesses(),
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )
    // The document was found held by another copy, so this instance gave up writing it.
    await recorder.seal()
    let prepare = PrepareForQuit(
      repository: repository,
      runtime: runtime,
      recorder: recorder,
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )

    let shutdown = await prepare()

    // That session is running under the other copy's agent: stopping it, or writing a status
    // about it, would be a statement about somebody else's process.
    #expect(shutdown.closed.isEmpty)
    #expect(await runtime.detached.isEmpty)
    #expect(await repository.status(of: theirs.id) == .active)
    #expect(await store.read() == nil)
  }

  @Test("A store that cannot be read still stops what this instance recorded")
  func stopsRecordedSessionsWhenTheStoreIsUnreadable() async {
    let unreadable = UnreadableRepository()
    let journal = Journal()
    let store = EphemeralSessionRuntimeStateStore()
    let runtime = SpyRuntime(journal: journal)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: StubProcesses(),
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )
    let recorded = SessionID()
    await recorder.started(recorded, processGroup: 5555)
    let prepare = PrepareForQuit(
      repository: unreadable,
      runtime: runtime,
      recorder: recorder,
      clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_500))
    )

    let shutdown = await prepare()

    #expect(await runtime.detached == [recorded])
    // Nothing could be closed, so nothing is claimed as resumable: the session is still stored
    // active, and the next launch reads that as the unexpected stop it is.
    #expect(shutdown.closed.isEmpty)
    #expect(await store.read()?.phase == .stopped)
    #expect(await store.read()?.sessions.isEmpty == true)
  }
}

// MARK: - Doubles

/// The order in which things happened, which is the whole assertion of this suite.
private actor Journal {
  private(set) var entries: [String] = []

  func record(_ entry: String) {
    entries.append(entry)
  }

  func clear() {
    entries.removeAll()
  }
}

private actor MutableRepository: SessionRepository {
  private var stored: [WorkSession]
  private let journal: Journal

  init(sessions: [WorkSession], journal: Journal) {
    stored = sessions
    self.journal = journal
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
  ) async throws -> WorkSession? {
    guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
    var session = stored[index]
    try transform(&session)
    stored[index] = session
    await journal.record("close:\(id)")
    return session
  }
}

private actor UnreadableRepository: SessionRepository {
  struct Unreadable: Error {}

  func sessions() throws -> [WorkSession] { throw Unreadable() }

  func session(id: SessionID) throws -> WorkSession? { throw Unreadable() }

  func save(_ session: WorkSession) throws { throw Unreadable() }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    throw Unreadable()
  }
}

/// A runtime whose stops wait for each other, so a sequential quit can be told from a concurrent
/// one by what overlapped rather than by a stopwatch.
private actor SlowRuntime: SessionRuntime {
  private(set) var highestConcurrency = 0
  private var inFlight = 0
  private let journal: Journal

  init(journal: Journal) {
    self.journal = journal
  }

  func detach(_ id: SessionID) async -> SessionDetachOutcome {
    inFlight += 1
    highestConcurrency = max(highestConcurrency, inFlight)
    await journal.record("detach:\(id)")
    for _ in 0..<4 { await Task.yield() }
    inFlight -= 1
    return .stopped
  }

  func dispose(_ id: SessionID) async {}
}

private actor SpyRuntime: SessionRuntime {
  private(set) var detached: [SessionID] = []
  private let journal: Journal

  init(journal: Journal) {
    self.journal = journal
  }

  func detach(_ id: SessionID) async -> SessionDetachOutcome {
    detached.append(id)
    await journal.record("detach:\(id)")
    return .stopped
  }

  func dispose(_ id: SessionID) async {}
}

/// A runtime document that says when it was written, so the order of the whole quit can be held
/// to the one the store's own rules depend on.
private struct JournalingRuntimeStateStore: SessionRuntimeStateStore {
  let store: EphemeralSessionRuntimeStateStore
  let journal: Journal

  func read() async -> SessionRuntimeState? { await store.read() }

  func write(_ state: SessionRuntimeState) async {
    await store.write(state)
    if state.phase == .stopped {
      await journal.record("runtime:stopped")
    }
  }

  func clear() async { await store.clear() }
}

private struct StubProcesses: ProcessLivenessProbe {
  func isAlive(processIdentifier: Int32) -> Bool { false }

  func startTime(of processIdentifier: Int32) -> Date? { nil }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool { true }
}

private struct FixedClock: SessionClock {
  let value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date { value }
}
