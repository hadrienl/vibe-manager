import Foundation
import Testing
import VibeApplication
import VibeDomain

@MainActor
@Suite("Restoring sessions at launch")
struct RestoreSessionsTests {
  // MARK: - Fixtures

  private func session(
    name: String,
    providerID: String = "stub",
    resumeIdentifier: String? = "kept-identifier"
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Split the signature check out.",
      agent: SessionAgentConfiguration(
        providerID: providerID, resumeIdentifier: resumeIdentifier),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: Date(timeIntervalSince1970: 1_700_000_100),
      repositories: [RepositoryContext(path: Fixture.folderPath)],
      legacyNotes: "The retry path is still untested."
    )
  }

  private func makeSubject(
    sessions: [WorkSession],
    launcher: StubLauncher = StubLauncher()
  ) -> (RestoreSessions, StubLauncher) {
    let repository = RestorationRepository(sessions: sessions)
    let restart = RestartSession(
      repository: repository,
      agents: RestorationRegistry(providers: [RestorationProvider()]),
      folders: RestorationFolders()
    )
    return (
      RestoreSessions(restart: restart, launcher: launcher, repository: repository), launcher
    )
  }

  private func intent(_ sessions: [WorkSession]) -> SessionRestoreIntent {
    SessionRestoreIntent(sessionIDs: sessions.map(\.id))
  }

  // MARK: - The queue

  @Test("Sessions come back one at a time, in the order the intention gives them")
  func restartsOneAtATimeInOrder() async {
    let first = session(name: "First")
    let second = session(name: "Second")
    let (restore, launcher) = makeSubject(sessions: [first, second])

    let outcomes = await restore(intent([first, second]))

    #expect(launcher.restarted == [first.id, second.id])
    #expect(launcher.highestConcurrency == 1)
    #expect(outcomes.map(\.didRestart) == [true, true])
    #expect(outcomes.first?.result == .restarted(.native(identifier: "kept-identifier")))
  }

  @Test("Progress is announced per session, counting from one")
  func announcesProgress() async {
    let first = session(name: "First")
    let second = session(name: "Second")
    let (restore, _) = makeSubject(sessions: [first, second])
    let recorder = ProgressRecorder()

    await restore(intent([first, second])) { recorder.record($0) }

    let expected = [
      Started(name: "First", index: 1, total: 2),
      Started(name: "Second", index: 2, total: 2),
    ]
    #expect(recorder.started == expected)
    #expect(recorder.finishedCount == 2)
  }

  // MARK: - What is not restored

  @Test("A session whose conversation cannot be resumed is left closed, with its reason")
  func doesNotSendASummaryNobodyHasRead() async {
    let resumable = session(name: "Resumable")
    let orphaned = session(name: "Orphaned", resumeIdentifier: nil)
    let (restore, launcher) = makeSubject(sessions: [resumable, orphaned])

    let outcomes = await restore(intent([resumable, orphaned]))

    #expect(launcher.restarted == [resumable.id])
    #expect(
      outcomes.last?.result
        == .skipped(.needsConfirmation(.noResumeIdentifier(agentName: "Stub Agent"))))
    #expect(outcomes.last?.sentence != nil)
    #expect(outcomes.last?.suggestion != nil)
  }

  @Test("An unavailable agent does not stop the sessions behind it in the queue")
  func oneRefusalDoesNotStopTheQueue() async {
    let missingAgent = session(name: "Missing agent", providerID: "not-installed")
    let healthy = session(name: "Healthy")
    let (restore, launcher) = makeSubject(sessions: [missingAgent, healthy])

    let outcomes = await restore(intent([missingAgent, healthy]))

    #expect(launcher.restarted == [healthy.id])
    #expect(outcomes.first?.result == .skipped(.refused(.agentUnknown("not-installed"))))
    #expect(outcomes.first?.sentence?.contains("not-installed") == true)
    #expect(outcomes.last?.didRestart == true)
  }

  @Test("A session that is already running is left alone, and is not a failure")
  func leavesARunningSessionAlone() async {
    let subject = session(name: "Already up")
    let launcher = StubLauncher(running: [subject.id])
    let (restore, _) = makeSubject(sessions: [subject], launcher: launcher)

    let outcomes = await restore(intent([subject]))

    #expect(launcher.restarted.isEmpty)
    #expect(outcomes.first?.result == .skipped(.alreadyRunning))
    // Nothing went wrong, so the report has nothing to say about it.
    #expect(outcomes.first?.sentence == nil)
  }

  @Test("A launch that never reached a process is reported with the launcher's own sentence")
  func reportsAFailedLaunch() async {
    let subject = session(name: "Doomed")
    let launcher = StubLauncher(
      failure: SessionRestartAttempt(
        started: false,
        message: "No pseudo terminal could be allocated.",
        suggestion: "Close some terminals, then try again."
      )
    )
    let (restore, _) = makeSubject(sessions: [subject], launcher: launcher)

    let outcomes = await restore(intent([subject]))

    #expect(
      outcomes.first?.result
        == .failed(
          message: "No pseudo terminal could be allocated.",
          suggestion: "Close some terminals, then try again."
        )
    )
  }

  @Test("A session that has gone from the store still gets a line of its own")
  func reportsAMissingSession() async {
    let subject = session(name: "Gone")
    let (restore, launcher) = makeSubject(sessions: [])

    let outcomes = await restore(SessionRestoreIntent(sessionIDs: [subject.id]))

    #expect(launcher.restarted.isEmpty)
    #expect(outcomes.first?.result == .skipped(.refused(.sessionMissing)))
    #expect(outcomes.count == 1)
  }

  @Test("A session that never ran is not started unattended either: it would send its prompt")
  func doesNotStartASessionThatNeverRan() async {
    let neverRan = SessionDraft(
      name: "Never ran",
      initialPrompt: "Split the signature check out.",
      providerID: "stub",
      workingDirectoryPath: Fixture.folderPath
    )
    .session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (restore, launcher) = makeSubject(sessions: [neverRan])

    let outcomes = await restore(SessionRestoreIntent(sessionIDs: [neverRan.id]))

    #expect(launcher.restarted.isEmpty)
    #expect(outcomes.first?.didRestart == false)
    #expect(outcomes.first?.sentence != nil)
  }

  // MARK: - Cancellation

  @Test("A cancelled restoration launches nothing at all")
  func cancelledBeforeItStartsLaunchesNothing() async {
    let first = session(name: "First")
    let second = session(name: "Second")
    let (restore, launcher) = makeSubject(sessions: [first, second])

    let task = Task { await restore(self.intent([first, second])) }
    task.cancel()
    let outcomes = await task.value

    #expect(launcher.restarted.isEmpty)
    #expect(outcomes.map(\.wasCancelled) == [true, true])
    // Every session still gets an outcome: a queue that returned a short list would leave the
    // report unable to say what happened to the rest.
    #expect(outcomes.count == 2)
  }

  @Test("Cancelling mid-queue stops the next session and leaves the running one alone")
  func cancellingEmptiesTheRestOfTheQueue() async {
    let first = session(name: "First")
    let second = session(name: "Second")
    let third = session(name: "Third")
    let (restore, launcher) = makeSubject(sessions: [first, second, third])
    let handle = TaskHandle()

    handle.task = Task {
      await restore(self.intent([first, second, third])) { progress in
        // Called off the moment the first session is back, as the Cancel button would.
        if case .finished = progress { handle.task?.cancel() }
      }
    }
    let outcomes = await handle.task?.value ?? []

    #expect(launcher.restarted == [first.id])
    #expect(outcomes.map(\.wasCancelled) == [false, true, true])
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

private struct Started: Equatable {
  let name: String
  let index: Int
  let total: Int
}

@MainActor
private final class ProgressRecorder {
  private(set) var started: [Started] = []
  private(set) var finishedCount = 0

  func record(_ progress: SessionRestoreProgress) {
    switch progress {
    case .started(_, let name, let index, let total):
      started.append(Started(name: name, index: index, total: total))
    case .finished:
      finishedCount += 1
    }
  }
}

@MainActor
private final class TaskHandle {
  var task: Task<[SessionRestoreOutcome], Never>?
}

/// A launcher that only remembers what it was asked to do — including whether two launches were
/// ever asked for at the same time, which the queue's whole shape is meant to prevent.
@MainActor
private final class StubLauncher: SessionRestarting {
  private(set) var restarted: [SessionID] = []
  private(set) var highestConcurrency = 0
  private var inFlight = 0
  private var running: Set<SessionID>
  private let failure: SessionRestartAttempt?

  init(running: Set<SessionID> = [], failure: SessionRestartAttempt? = nil) {
    self.running = running
    self.failure = failure
  }

  func isRunning(_ id: SessionID) -> Bool {
    running.contains(id)
  }

  func attemptRestart(_ restart: SessionRestart) async -> SessionRestartAttempt {
    inFlight += 1
    highestConcurrency = max(highestConcurrency, inFlight)
    defer { inFlight -= 1 }
    // A hop, so a queue that did not wait for one session before starting the next would be
    // caught by `highestConcurrency`.
    await Task.yield()
    if let failure { return failure }
    restarted.append(restart.session.id)
    running.insert(restart.session.id)
    return .started
  }
}
