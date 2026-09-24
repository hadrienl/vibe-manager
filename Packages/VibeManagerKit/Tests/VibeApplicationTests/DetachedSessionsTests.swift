import Foundation
import Testing
import VibeApplication
import VibeDomain

// Leaving the agents running when the application quits, and finding them again (ADR 0016).

private let launch = Date(timeIntervalSince1970: 1_700_000_000)
private let quitAt = Date(timeIntervalSince1970: 1_700_000_600)
private let now = Date(timeIntervalSince1970: 1_700_009_999)
private let hostIdentity = TerminalHostIdentity(
  processIdentifier: 815, processStartedAt: Date(timeIntervalSince1970: 1_699_999_900))

private func session(
  _ name: String,
  status: SessionStatus = .active,
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
    repositories: [
      RepositoryContext(
        path: FileManager.default.temporaryDirectory
          .appendingPathComponent("vibe-fixture-folder", isDirectory: true).path)
    ]
  )
}

/// A terminal host a test decides on, and which says what it was asked.
actor FakeTerminalHost: TerminalHosting {
  private let status: TerminalHostStatus
  private let stopRequest: Date?
  private(set) var discarded: [SessionID] = []
  private(set) var goodbyes: [Bool] = []

  init(_ status: TerminalHostStatus, stopRequestedAt stopRequest: Date? = nil) {
    self.status = status
    self.stopRequest = stopRequest
  }

  func lastStopRequest() -> Date? { stopRequest }

  func reconnect() -> TerminalHostStatus { status }

  func hostIdentity() -> TerminalHostIdentity? {
    guard case .connected(let identity, _) = status else { return nil }
    return identity
  }

  func discard(_ id: SessionID) { discarded.append(id) }

  func relinquish(keepRunning: Bool) { goodbyes.append(keepRunning) }
}

/// Liveness from `RestorationProcesses`, and a boot time of the test's choosing.
private struct BootingProcesses: ProcessLivenessProbe {
  let processes: RestorationProcesses
  let booted: Date?

  func isAlive(processIdentifier: Int32) -> Bool {
    processes.isAlive(processIdentifier: processIdentifier)
  }

  func startTime(of processIdentifier: Int32) -> Date? {
    processes.startTime(of: processIdentifier)
  }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool {
    processes.terminate(processGroup: processGroup)
  }

  func bootTime() -> Date? { booted }
}

@Suite("Finding again the agents left running")
struct DetachedShutdownTests {
  private func detachedDocument(
    running: [SessionRuntimeRecord],
    resuming: [SessionID] = []
  ) -> SessionRuntimeState {
    SessionRuntimeState(
      phase: .detached,
      processIdentifier: 1_001,
      processStartedAt: Date(timeIntervalSince1970: 1_699_999_000),
      launchedAt: launch,
      updatedAt: quitAt,
      stoppedAt: quitAt,
      sessions: running,
      host: hostIdentity,
      resuming: resuming.map { SessionRuntimeRecord(sessionID: $0) }
    )
  }

  private func detect(
    sessions: [WorkSession],
    document: SessionRuntimeState,
    host: FakeTerminalHost,
    processes: RestorationProcesses = RestorationProcesses(),
    booted: Date? = nil
  ) async -> (PreviousShutdown, RestorationRepository, EphemeralSessionRuntimeStateStore) {
    let repository = RestorationRepository(sessions: sessions)
    let store = EphemeralSessionRuntimeStateStore(state: document)
    let probe = BootingProcesses(processes: processes, booted: booted)
    let recorder = SessionRuntimeRecorder(
      store: store, processIdentifier: 4242, probe: probe, clock: RestorationClock(now))
    let subject = DetectPreviousShutdown(
      repository: repository,
      recorder: recorder,
      processes: probe,
      clock: RestorationClock(now),
      processIdentifier: 4242,
      host: host
    )
    return (await subject(), repository, store)
  }

  @Test("A running agent is taken back as it is: still active, and nothing to resume")
  func reattachesRunningSessions() async {
    let running = session("Running")
    let host = FakeTerminalHost(
      .connected(
        hostIdentity,
        sessions: [HostedSessionSummary(id: running.id, state: .running(processIdentifier: 902))]
      ))

    let (verdict, repository, store) = await detect(
      sessions: [running],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: running.id)]),
      host: host
    )

    #expect(
      verdict
        == .detached(
          DetachedSessions(
            running: [running.id], ended: [], resume: SessionRestoreIntent(sessionIDs: []))
        ))
    #expect(await repository.status(of: running.id) == .active)
    // Claimed, so a crash from here on is read as this launch's crash, not as the quit's intention.
    #expect(await store.read()?.phase == .running)
    #expect(await store.read()?.processIdentifier == 4242)
  }

  @Test("An agent that ended while the application was closed is closed from when it ended")
  func closesWhatEndedWhileAway() async {
    let ended = session("Ended")
    let endedAt = Date(timeIntervalSince1970: 1_700_003_000)
    let host = FakeTerminalHost(
      .connected(
        hostIdentity,
        sessions: [HostedSessionSummary(id: ended.id, state: .exited(code: 0), endedAt: endedAt)]
      ))

    let (verdict, repository, _) = await detect(
      sessions: [ended],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: ended.id)]),
      host: host
    )

    guard case .detached(let detached) = verdict else {
      Issue.record("Expected the detached verdict, got \(verdict)")
      return
    }
    #expect(detached.ended == [ended.id])
    #expect(detached.running.isEmpty)
    #expect(await repository.status(of: ended.id) == .closed)
    #expect(await repository.session(id: ended.id)?.closedAt == endedAt)
  }

  @Test("What the quit had to stop is resumed as a clean quit would, beside what kept running")
  func resumesWhatWasStopped() async {
    let running = session("Running")
    let stopped = session("Stopped in the application", status: .closed)
    let host = FakeTerminalHost(
      .connected(
        hostIdentity,
        sessions: [HostedSessionSummary(id: running.id, state: .running(processIdentifier: 902))]
      ))

    let (verdict, _, _) = await detect(
      sessions: [running, stopped],
      document: detachedDocument(
        running: [SessionRuntimeRecord(sessionID: running.id)], resuming: [stopped.id]),
      host: host
    )

    guard case .detached(let detached) = verdict else {
      Issue.record("Expected the detached verdict, got \(verdict)")
      return
    }
    #expect(detached.running == [running.id])
    #expect(detached.resume.sessionIDs == [stopped.id])
  }

  @Test("A session the host lost is closed and resumed, and its process group looked for")
  func resumesWhatTheHostLost() async {
    let lost = session("Lost")
    let processes = RestorationProcesses(
      alive: [902], startTimes: [902: Date(timeIntervalSince1970: 1_700_000_050)])
    let host = FakeTerminalHost(.connected(hostIdentity, sessions: []))

    let (verdict, repository, _) = await detect(
      sessions: [lost],
      document: detachedDocument(running: [
        SessionRuntimeRecord(
          sessionID: lost.id, processGroup: 902,
          processStartedAt: Date(timeIntervalSince1970: 1_700_000_050))
      ]),
      host: host,
      processes: processes
    )

    guard case .detached(let detached) = verdict else {
      Issue.record("Expected the detached verdict, got \(verdict)")
      return
    }
    #expect(detached.resume.sessionIDs == [lost.id])
    #expect(await repository.status(of: lost.id) == .closed)
    #expect(processes.terminated == [902])
  }

  @Test("What the host holds for a session the store no longer calls active is let go")
  func discardsWhatNobodyWants() async {
    let archived = session("Archived", status: .archived)
    let host = FakeTerminalHost(
      .connected(
        hostIdentity,
        sessions: [HostedSessionSummary(id: archived.id, state: .running(processIdentifier: 903))]
      ))

    _ = await detect(
      sessions: [archived], document: detachedDocument(running: []), host: host)

    #expect(await host.discarded == [archived.id])
  }

  @Test("A host gone after a restart of the Mac reads as a clean quit: the sessions are resumed")
  func hostLostToARestartResumes() async {
    let running = session("Running")
    let (verdict, repository, _) = await detect(
      sessions: [running],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: running.id)]),
      host: FakeTerminalHost(.absent),
      booted: Date(timeIntervalSince1970: 1_700_005_000)
    )

    #expect(verdict == .clean(SessionRestoreIntent(sessionIDs: [running.id])))
    #expect(await repository.status(of: running.id) == .closed)
  }

  @Test("A host told to stop after the quit — a logout — reads as a clean quit, too")
  func hostStoppedOnPurposeResumes() async {
    let running = session("Running")
    let (verdict, _, _) = await detect(
      sessions: [running],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: running.id)]),
      host: FakeTerminalHost(.absent, stopRequestedAt: Date(timeIntervalSince1970: 1_700_004_000)),
      booted: Date(timeIntervalSince1970: 1_699_000_000)
    )

    #expect(verdict == .clean(SessionRestoreIntent(sessionIDs: [running.id])))
  }

  @Test("A stop request older than the quit says nothing about this host")
  func staleStopRequestIsIgnored() async {
    let running = session("Running")
    let (verdict, _, _) = await detect(
      sessions: [running],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: running.id)]),
      host: FakeTerminalHost(.absent, stopRequestedAt: Date(timeIntervalSince1970: 1_699_500_000)),
      booted: Date(timeIntervalSince1970: 1_699_000_000)
    )

    guard case .unexpected = verdict else {
      Issue.record("Expected the sessions to be offered, got \(verdict)")
      return
    }
  }

  @Test("A host gone without a restart crashed: the sessions are offered, leftovers stopped")
  func hostLostWithoutARestartOffers() async {
    let running = session("Running")
    let processes = RestorationProcesses(
      alive: [902], startTimes: [902: Date(timeIntervalSince1970: 1_700_000_050)])

    let (verdict, _, _) = await detect(
      sessions: [running],
      document: detachedDocument(running: [
        SessionRuntimeRecord(
          sessionID: running.id, processGroup: 902,
          processStartedAt: Date(timeIntervalSince1970: 1_700_000_050))
      ]),
      host: FakeTerminalHost(.absent),
      processes: processes,
      booted: Date(timeIntervalSince1970: 1_699_000_000)
    )

    guard case .unexpected(let intent, _) = verdict else {
      Issue.record("Expected the sessions to be offered, got \(verdict)")
      return
    }
    #expect(intent.sessionIDs == [running.id])
    #expect(processes.terminated == [902])
  }

  @Test("A host that is ours but will not answer now is left alone, and so is everything else")
  func unavailableHostIsLeftAlone() async {
    let running = session("Running")
    let processes = RestorationProcesses(
      alive: [815, 902],
      startTimes: [
        815: Date(timeIntervalSince1970: 1_699_999_900),
        902: Date(timeIntervalSince1970: 1_700_000_050),
      ])

    let (verdict, repository, store) = await detect(
      sessions: [running],
      document: detachedDocument(running: [
        SessionRuntimeRecord(
          sessionID: running.id, processGroup: 902,
          processStartedAt: Date(timeIntervalSince1970: 1_700_000_050))
      ]),
      host: FakeTerminalHost(.unavailable(reason: "Busy")),
      processes: processes
    )

    #expect(verdict == .hostUnavailable(reason: "Busy"))
    #expect(processes.terminated.isEmpty)
    #expect(await repository.status(of: running.id) == .active)
    // Still the quit's document: the next launch asks the host again.
    #expect(await store.read()?.phase == .detached)
  }

  @Test("A host that cannot be verified is stopped, once identified, and its sessions offered")
  func unverifiableHostIsStopped() async {
    let running = session("Running")
    let processes = RestorationProcesses(
      alive: [815], startTimes: [815: Date(timeIntervalSince1970: 1_699_999_900)])

    let (verdict, _, _) = await detect(
      sessions: [running],
      document: detachedDocument(running: [SessionRuntimeRecord(sessionID: running.id)]),
      host: FakeTerminalHost(.refused(reason: "Not ours")),
      processes: processes
    )

    guard case .unexpected(let intent, _) = verdict else {
      Issue.record("Expected the sessions to be offered, got \(verdict)")
      return
    }
    #expect(intent.sessionIDs == [running.id])
    #expect(processes.terminated == [815])
  }
}

@Suite("Quitting with the agents left running")
struct DetachForQuitTests {
  /// Hands off the sessions it is told to, and stops the others.
  private actor Runtime: SessionRuntime, SessionHandOff {
    let hosted: Set<SessionID>
    private(set) var stopped: [SessionID] = []

    init(hosted: Set<SessionID>) {
      self.hosted = hosted
    }

    func handOff(_ id: SessionID) -> Bool { hosted.contains(id) }

    func detach(_ id: SessionID) -> SessionDetachOutcome {
      stopped.append(id)
      return .stopped
    }

    func dispose(_ id: SessionID) {}
  }

  private func makeSubject(
    sessions: [WorkSession],
    hosted: Set<SessionID>,
    groups: [SessionID: Int32] = [:]
  ) async -> (
    DetachForQuit, RestorationRepository, Runtime, FakeTerminalHost,
    EphemeralSessionRuntimeStateStore
  ) {
    let repository = RestorationRepository(sessions: sessions)
    let runtime = Runtime(hosted: hosted)
    let host = FakeTerminalHost(.connected(hostIdentity, sessions: []))
    let store = EphemeralSessionRuntimeStateStore()
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: 4242,
      probe: RestorationProcesses(startTimes: [902: Date(timeIntervalSince1970: 1_700_000_050)]),
      clock: RestorationClock(quitAt)
    )
    for (id, group) in groups {
      await recorder.started(id, processGroup: group)
    }
    let subject = DetachForQuit(
      repository: repository, runtime: runtime, handOff: runtime, host: host, recorder: recorder,
      clock: RestorationClock(quitAt))
    return (subject, repository, runtime, host, store)
  }

  @Test("A hosted agent is left running, still active, with its process group written down")
  func leavesHostedSessionsRunning() async {
    let hosted = session("Hosted")
    let (subject, repository, runtime, host, store) = await makeSubject(
      sessions: [hosted], hosted: [hosted.id], groups: [hosted.id: 902])

    let detachment = await subject()

    #expect(detachment.kept == [hosted.id])
    #expect(await runtime.stopped.isEmpty)
    #expect(await repository.status(of: hosted.id) == .active)
    let document = await store.read()
    #expect(document?.phase == .detached)
    #expect(document?.host == hostIdentity)
    #expect(document?.sessions.first?.processGroup == 902)
    #expect(document?.sessions.first?.processStartedAt != nil)
    #expect(await host.goodbyes == [true])
  }

  @Test("An agent running in the application itself is stopped, closed, and resumed next time")
  func stopsWhatCannotBeLeft() async {
    let hosted = session("Hosted", updatedAt: Date(timeIntervalSince1970: 1_700_000_300))
    let local = session("Local", updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    let (subject, repository, runtime, _, store) = await makeSubject(
      sessions: [hosted, local], hosted: [hosted.id])

    let detachment = await subject()

    #expect(detachment.kept == [hosted.id])
    #expect(await runtime.stopped == [local.id])
    #expect(await repository.status(of: local.id) == .closed)
    #expect(await store.read()?.resuming?.map(\.sessionID) == [local.id])
  }

  @Test("With nothing left running, it is a plain quit, and the host is told so")
  func nothingHostedIsAPlainQuit() async {
    let local = session("Local")
    let (subject, _, _, host, store) = await makeSubject(sessions: [local], hosted: [])

    let detachment = await subject()

    #expect(detachment.kept.isEmpty)
    #expect(await store.read()?.phase == .stopped)
    #expect(await store.read()?.sessions.map(\.sessionID) == [local.id])
    #expect(await host.goodbyes == [false])
  }
}
