import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Restoring sessions when the workspace opens")
struct SessionRestorationTests {
  // MARK: - Fixtures

  private static let launch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let lastSeen = Date(timeIntervalSince1970: 1_700_000_600)

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-restore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func session(
    name: String = "Refactor the webhook",
    status: SessionStatus = .closed,
    resumeIdentifier: String? = "kept-identifier",
    path: String
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Split the signature check out.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: resumeIdentifier),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: status == .active ? nil : Date(timeIntervalSince1970: 1_700_000_100),
      repositories: [RepositoryContext(path: path)]
    )
  }

  private func document(
    phase: SessionRuntimeState.Phase,
    processIdentifier: Int32 = 1_001,
    sessions: [SessionRuntimeRecord]
  ) -> SessionRuntimeState {
    SessionRuntimeState(
      phase: phase,
      processIdentifier: processIdentifier,
      launchedAt: Self.launch,
      updatedAt: Self.lastSeen,
      stoppedAt: phase == .stopped ? Self.lastSeen : nil,
      sessions: sessions
    )
  }

  private struct Workspace {
    let model: AppModel
    let launcher: SessionLauncher
    let repository: WorkspaceRepository
    let runtime: EphemeralSessionRuntimeStateStore
    let recorder: SessionRuntimeRecorder
  }

  private func makeWorkspace(
    sessions: [WorkSession],
    document: SessionRuntimeState? = nil,
    alive: Set<Int32> = [],
    runtime: EphemeralSessionRuntimeStateStore? = nil,
    repository: WorkspaceRepository? = nil,
    processIdentifier: Int32 = 4_242,
    probeGate: ProbeGate? = nil
  ) -> Workspace {
    let repository = repository ?? WorkspaceRepository(sessions: sessions)
    let store = runtime ?? EphemeralSessionRuntimeStateStore(state: document)
    let processes = StubProcesses(alive: alive)
    let recorder = SessionRuntimeRecorder(
      store: store,
      processIdentifier: processIdentifier,
      probe: processes
    )
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider(probeGate: probeGate)])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(),
      repository: repository,
      agents: registry,
      recorder: recorder,
      viewportTimeout: .zero
    )
    let model = AppModel(
      repository: repository,
      agents: registry,
      launcher: launcher,
      runtimeRecorder: recorder,
      processes: processes
    )
    return Workspace(
      model: model,
      launcher: launcher,
      repository: repository,
      runtime: store,
      recorder: recorder
    )
  }

  // MARK: - A clean quit

  @Test("A clean quit brings the sessions back on their own, and says nothing about it")
  func aCleanQuitIsRestored() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(workspace.launcher.isRunning(subject.id))
    #expect(await workspace.repository.status(of: subject.id) == .active)
    #expect(workspace.model.restoration == nil)
    #expect(workspace.model.restoreOffer == nil)
    // Nothing needed the user, so nothing is put in front of them.
    #expect(workspace.model.restoreReport == nil)
  }

  @Test("What came back is written down again, so the next launch knows about it")
  func recordsWhatItRestored() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    let state = await workspace.runtime.read()
    #expect(state?.phase == .running)
    #expect(state?.sessions.map(\.sessionID) == [subject.id])
    #expect(state?.sessions.first?.processGroup == 4_242)
  }

  @Test("A session whose conversation is gone stays closed, with its reason in the report")
  func aSessionThatWouldNeedASummaryIsLeftToTheUser() async {
    let path = folder()
    let subject = session(status: .closed, resumeIdentifier: nil, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(!workspace.launcher.isRunning(subject.id))
    #expect(await workspace.repository.status(of: subject.id) == .closed)
    #expect(workspace.model.restoreReport?.lines.count == 1)
    #expect(workspace.model.restoreReport?.lines.first?.name == "Refactor the webhook")
    #expect(workspace.model.restoreReport?.restartedCount == 0)
    // And the command that finishes the job by hand is offered, summary and all.
    let listed = workspace.model.sessions.first { $0.id == subject.id }
    #expect(listed.map(workspace.model.canRestart) == true)
  }

  // MARK: - An unexpected stop

  @Test("An unexpected stop is offered, never taken: nothing is launched by itself")
  func anUnexpectedStopIsOffered() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )

    await workspace.model.load()

    #expect(workspace.model.restoreOffer?.sessionCount == 1)
    #expect(!workspace.launcher.isRunning(subject.id))
    // The store is honest again before the first list is drawn: nothing is running, so nothing
    // is stored active.
    #expect(await workspace.repository.status(of: subject.id) == .closed)
    #expect(workspace.model.sessions.first?.status == .closed)
  }

  @Test("The offer is on screen before the agents have answered their probes")
  func offersWithoutWaitingForTheDetections() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let gate = ProbeGate()
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)]),
      probeGate: gate
    )

    let launch = Task { await workspace.model.load() }
    // The detections are held until the end: the offer can only come before them.
    let deadline = ContinuousClock.now + .seconds(10)
    while workspace.model.restoreOffer == nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    // An offer asks no provider anything. Announced after the detections, it arrived on a cold
    // cache long after the user had decided their sessions were gone.
    #expect(workspace.model.restoreOffer?.sessionCount == 1)
    #expect(workspace.model.isRefreshingAgents)

    await gate.open()
    await launch.value
  }

  @Test("Accepting the offer restores the sessions, once")
  func acceptingTheOfferRestores() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    await workspace.model.load()

    await workspace.model.acceptRestoreOffer()

    #expect(workspace.launcher.isRunning(subject.id))
    #expect(workspace.model.restoreOffer == nil)
    #expect(await workspace.repository.status(of: subject.id) == .active)

    // Asked again, it has nothing left to do: the offer is gone with the intention it carried.
    await workspace.model.acceptRestoreOffer()
    #expect(await workspace.repository.status(of: subject.id) == .active)
  }

  @Test("Declining the offer leaves the sessions closed and whole")
  func decliningTheOfferKeepsEverything() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(phase: .running, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    await workspace.model.load()

    workspace.model.dismissRestoreOffer()

    #expect(workspace.model.restoreOffer == nil)
    #expect(!workspace.launcher.isRunning(subject.id))
    let stored = await workspace.repository.session(id: subject.id)
    #expect(stored?.status == .closed)
    #expect(stored?.agent?.resumeIdentifier == "kept-identifier")
  }

  @Test("A leftover process nobody can identify is reported, not signalled")
  func reportsAnUnidentifiableLeftover() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(
        phase: .running,
        sessions: [SessionRuntimeRecord(sessionID: subject.id, processGroup: 7_003)]
      ),
      alive: [7_003]
    )

    await workspace.model.load()

    #expect(workspace.model.restoreOffer?.leftoverProcessIdentifiers == [7_003])
    #expect(workspace.model.restoreOffer?.suggestion?.contains("7003") == true)
  }

  // MARK: - The report

  @Test("A cancelled restoration says how many sessions it left closed")
  func reportsWhatACancellationLeftClosed() async {
    let path = folder()
    let first = session(name: "First", path: path)
    let second = session(name: "Second", path: path)
    let workspace = makeWorkspace(sessions: [first, second])

    await workspace.model.finishRestore(with: [
      SessionRestoreOutcome(
        sessionID: first.id, sessionName: "First", result: .restarted(.native(identifier: "k"))),
      SessionRestoreOutcome(
        sessionID: second.id, sessionName: "Second", result: .skipped(.cancelled)),
    ])

    let report = workspace.model.restoreReport
    #expect(report?.cancelledCount == 1)
    #expect(report?.lines.isEmpty == true)
    #expect(report?.message == "1 more was left closed when you cancelled. 1 session came back.")
  }

  @Test("A restoration where everything came back says nothing")
  func staysSilentWhenEverythingCameBack() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let workspace = makeWorkspace(sessions: [subject])

    await workspace.model.finishRestore(with: [
      SessionRestoreOutcome(
        sessionID: subject.id,
        sessionName: subject.name,
        result: .restarted(.native(identifier: "kept-identifier"))
      )
    ])

    #expect(workspace.model.restoreReport == nil)
  }

  // MARK: - A second copy

  @Test("A second copy of the application is named, and nothing here is touched")
  func aSecondCopyIsDetected() async {
    let path = folder()
    let subject = session(status: .active, path: path)
    let workspace = makeWorkspace(
      sessions: [subject],
      document: document(
        phase: .running,
        processIdentifier: 1_001,
        sessions: [SessionRuntimeRecord(sessionID: subject.id)]
      ),
      alive: [1_001]
    )

    await workspace.model.load()

    #expect(workspace.model.otherInstanceProcessIdentifier == 1_001)
    #expect(workspace.model.restoreOffer == nil)
    #expect(!workspace.launcher.isRunning(subject.id))
    // Those sessions belong to the other copy: closing them here would stop its agents' work
    // from ever being written down as finished.
    #expect(await workspace.repository.status(of: subject.id) == .active)
  }

  // MARK: - The full circle

  @Test("Quitting and reopening puts the same session back, with everything it carried")
  func theFullCircle() async {
    let path = folder()
    let subject = session(status: .closed, path: path)
    let repository = WorkspaceRepository(sessions: [subject])
    let runtime = EphemeralSessionRuntimeStateStore(
      state: document(phase: .stopped, sessions: [SessionRuntimeRecord(sessionID: subject.id)])
    )
    let first = makeWorkspace(
      sessions: [subject], runtime: runtime, repository: repository, processIdentifier: 4_242)
    await first.model.load()
    #expect(first.launcher.isRunning(subject.id))

    // Quitting: the same sequence the application delegate runs.
    let prepare = PrepareForQuit(
      repository: repository,
      runtime: first.launcher,
      recorder: first.recorder
    )
    let shutdown = await prepare()

    #expect(shutdown.closed.map(\.id) == [subject.id])
    #expect(await runtime.read()?.phase == .stopped)
    #expect(await runtime.read()?.sessions.map(\.sessionID) == [subject.id])

    // Opening again, over the same store and the same document.
    let second = makeWorkspace(
      sessions: [], runtime: runtime, repository: repository, processIdentifier: 4_243)
    await second.model.load()

    #expect(second.launcher.isRunning(subject.id))
    let restored = await repository.session(id: subject.id)
    #expect(restored?.status == .active)
    #expect(restored?.agent?.resumeIdentifier == "kept-identifier")
    #expect(restored?.repositories.first?.path == path)
    #expect(restored?.name == subject.name)
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

/// A system whose processes the test decides on.
private final class StubProcesses: ProcessLivenessProbe, @unchecked Sendable {
  private let lock = NSLock()
  private let alive: Set<Int32>
  private var killed: [Int32] = []

  init(alive: Set<Int32> = []) {
    self.alive = alive
  }

  var terminated: [Int32] {
    lock.withLock { killed }
  }

  func isAlive(processIdentifier: Int32) -> Bool { alive.contains(processIdentifier) }

  /// Never answered: every recorded group is therefore unidentifiable, which is the case that
  /// must be reported rather than signalled.
  func startTime(of _: Int32) -> Date? { nil }

  @discardableResult
  func terminate(processGroup: Int32) -> Bool {
    lock.withLock { killed.append(processGroup) }
    return true
  }
}
