import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

private actor ClaudeCaptureRepository: SessionRepository {
  private var stored: WorkSession
  private(set) var saveCount = 0

  init(stored: WorkSession) {
    self.stored = stored
  }

  func sessions() -> [WorkSession] {
    [stored]
  }

  func session(id: SessionID) -> WorkSession? {
    stored.id == id ? stored : nil
  }

  func save(_ session: WorkSession) {
    stored = session
    saveCount += 1
  }
}

/// A session that only appears after a few attempts, the way a pane can start before the row
/// it belongs to has been written.
private actor LateRepository: SessionRepository {
  private var stored: WorkSession?
  private let appearsAfter: Int
  private var reads = 0

  init(session: WorkSession, appearsAfter: Int) {
    self.appearsAfter = appearsAfter
    pending = session
  }

  private var pending: WorkSession

  func sessions() -> [WorkSession] {
    stored.map { [$0] } ?? []
  }

  func session(id: SessionID) -> WorkSession? {
    reads += 1
    if reads > appearsAfter, stored == nil {
      stored = pending
    }
    return stored?.id == id ? stored : nil
  }

  func save(_ session: WorkSession) {
    stored = session
  }
}

private actor NeverRepository: SessionRepository {
  func sessions() -> [WorkSession] { [] }
  func session(id: SessionID) -> WorkSession? { nil }
  func save(_ session: WorkSession) {}
}

/// A conversation the CLI wrote down right away.
private struct WrittenTranscript: ClaudeCodeTranscriptWatching {
  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool { true }
}

/// A launch that never reached a first exchange: every look lasts its whole window.
private struct NoTranscript: ClaudeCodeTranscriptWatching {
  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    try? await Task.sleep(for: timeout)
    return false
  }
}

/// A conversation the CLI only writes down with its first message, `appearsAfter` into the
/// launch: the way a session started without a prompt waits for the user (#138). Time is counted,
/// not spent: a watch shorter than that comes back empty at once.
private actor LateTranscript: ClaudeCodeTranscriptWatching {
  private let appearsAfter: Duration
  private var watched: Duration = .zero

  init(appearsAfter: Duration) {
    self.appearsAfter = appearsAfter
  }

  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    watched += timeout
    return watched >= appearsAfter
  }
}

/// A transcript on disk, whose last look — the one `finish` makes — holds until the test lets it
/// answer.
private actor HeldLastLook: ClaudeCodeTranscriptWatching {
  private(set) var isHolding = false
  private var held: CheckedContinuation<Void, Never>?

  func release() {
    held?.resume()
    held = nil
  }

  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    guard timeout == .zero else {
      try? await Task.sleep(for: timeout)
      return false
    }
    isHolding = true
    await withCheckedContinuation { held = $0 }
    return true
  }
}

/// Waits for a state, never for a deadline.
private func eventually(_ condition: () async -> Bool) async {
  while await !condition() { await Task.yield() }
}

/// A transcript on disk from the moment the test says so, and not before.
private actor TranscriptOnDisk: ClaudeCodeTranscriptWatching {
  private var isWritten = false

  func write() {
    isWritten = true
  }

  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    if isWritten || timeout == .zero { return isWritten }
    // Asleep for the whole look, so the watch cannot see the file before the process ends.
    try? await Task.sleep(for: timeout)
    return false
  }
}

private func claudeSession() -> WorkSession {
  WorkSession(
    name: "Refonte du parseur",
    agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "claude-opus-5")
  )
}

private func plan(arguments: [String]) -> AgentLaunchPlan {
  AgentLaunchPlan(
    providerID: ClaudeCodeAgentProvider.id,
    executablePath: "/opt/homebrew/bin/claude",
    arguments: arguments,
    environment: [:],
    workingDirectoryPath: "/Users/test/app",
    promptDelivery: .none
  )
}

@Suite("Claude Code session identifier capture")
struct ClaudeCodeSessionIdentifierCaptureTests {
  private let identifier = "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04"

  @Test("The identifier the plan assigned is stored on the session")
  func storesAssignedIdentifier() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: WrittenTranscript()
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    #expect(await capture.settled() == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A resume plan changes nothing: the identifier is already stored")
  func resumePlanIsInert() async throws {
    var session = claudeSession()
    session.agent?.resumeIdentifier = identifier
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: WrittenTranscript()
    )

    let recorded = await capture.record(plan: plan(arguments: ["--resume", identifier]))

    #expect(recorded == nil)
    #expect(await repository.saveCount == 0)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A new launch of the same session replaces the previous conversation")
  func replacesOnRelaunch() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: WrittenTranscript()
    )
    let second = "8c1d0b7e-1111-4222-8333-444455556666"

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    await capture.record(plan: plan(arguments: ["--session-id", second]))

    #expect(await capture.settled() == second)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == second)
  }

  @Test("A plan without an assigned identifier writes nothing")
  func ignoresPlansWithoutIdentifier() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: WrittenTranscript()
    )

    await capture.record(plan: plan(arguments: ["--model", "claude-opus-5"]))

    #expect(await capture.identifier == nil)
    #expect(await repository.saveCount == 0)
  }

  @Test("A session that is not written yet is waited for, not given up on")
  func retriesUntilTheSessionExists() async {
    let session = claudeSession()
    let repository = LateRepository(session: session, appearsAfter: 2)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: WrittenTranscript(),
      persistenceWindow: .seconds(5)
    )

    let assigned = await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    #expect(assigned == identifier)

    #expect(await capture.settled() == identifier)
    #expect(await capture.unstoredIdentifier == nil)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A conversation the CLI never wrote leaves no identifier to resume")
  func waitsForTheConversationToExist() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: NoTranscript()
    )

    let assigned = await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    // The process ends without a first message: the watch stops with it.
    await capture.finish()

    #expect(assigned == identifier)
    #expect(await capture.settled() == nil)
    #expect(await capture.unstoredIdentifier == nil)
    #expect(await repository.saveCount == 0)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == nil)
  }

  @Test("A conversation written long after the launch is still stored (#138)")
  func waitsAsLongAsTheProcessLives() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    // The first message, written ten minutes after the launch.
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: LateTranscript(appearsAfter: .seconds(600))
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    #expect(await capture.settled() == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A launch whose end is never reported stops watching after the limit")
  func watchHasALimit() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: NoTranscript(),
      transcriptWatchLimit: .milliseconds(20)
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    // No `finish`: the watch ends on its own.
    #expect(await capture.settled() == nil)
    #expect(await repository.saveCount == 0)
  }

  @Test("Every report of the end returns once the identifier is written")
  func concurrentFinishesAwaitTheFirst() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let transcripts = HeldLastLook()
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: transcripts
    )
    await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    let first = Task { await capture.finish() }
    await eventually { await transcripts.isHolding }
    let second = Task {
      await capture.finish()
      return await repository.session(id: session.id)?.agent?.resumeIdentifier
    }
    await eventually { await capture.finishRequests == 2 }
    await transcripts.release()

    #expect(await second.value == identifier)
    await first.value
  }

  @Test("A conversation written just before the process ended is stored when it ends")
  func looksOnceMoreWhenTheProcessEnds() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let transcripts = TranscriptOnDisk()
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: transcripts,
      transcriptWatchLimit: .seconds(3600)
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    await transcripts.write()
    await capture.finish()

    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A conversation still unwritten is handed over, and nothing once it is stored (#141)")
  func handsOverWhatItStillWaitsFor() async {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let transcripts = TranscriptOnDisk()
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      transcripts: transcripts,
      transcriptWatchLimit: .seconds(3600)
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    await capture.finish()

    #expect(await capture.awaitedIdentifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == nil)

    // The next instance takes the watch up with no plan, only the identifier handed over.
    let adopted = ClaudeCodeLaunchObserver(
      capture: ClaudeCodeSessionIdentifierCapture(
        sessionID: session.id,
        record: RecordAgentResumeIdentifier(repository: repository),
        transcripts: transcripts,
        transcriptWatchLimit: .seconds(3600)
      ))
    await adopted.adopted(awaitedResumeIdentifier: identifier)
    #expect(await adopted.awaitedResumeIdentifier() == identifier)
    await transcripts.write()
    await adopted.finished()

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await adopted.awaitedResumeIdentifier() == nil)
  }

  @Test("An identifier that could never be stored is surfaced, not dropped")
  func reportsUnstoredIdentifier() async {
    let session = claudeSession()
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: NeverRepository()),
      transcripts: WrittenTranscript(),
      persistenceWindow: .milliseconds(400)
    )

    let assigned = await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    #expect(assigned == identifier)
    #expect(await capture.settled() == nil)
    // The conversation exists on disk; saying nothing would lose it silently.
    #expect(await capture.unstoredIdentifier == identifier)
    #expect(await capture.assignedIdentifier == identifier)
  }
}

@Suite("Claude Code transcript watcher")
struct ClaudeCodeTranscriptWatcherTests {
  private let identifier = "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04"

  @Test("A transcript is recognised whatever project directory the CLI filed it under")
  func findsTheTranscript() async throws {
    let projects = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("claude-projects-\(UUID().uuidString)", isDirectory: true)
    let project = projects.appendingPathComponent("-Users-test-app", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projects) }

    let watcher = ClaudeCodeTranscriptWatcher(
      projectsDirectory: projects, pollInterval: .milliseconds(20))
    #expect(
      await watcher.awaitTranscript(identifier: identifier, timeout: .milliseconds(100)) == false)

    try Data("{}\n".utf8).write(
      to: project.appendingPathComponent("\(identifier).jsonl", isDirectory: false))
    #expect(await watcher.awaitTranscript(identifier: identifier, timeout: .milliseconds(100)))
  }

  @Test("The watch slows down after its first period, up to the slowest pace")
  func slowsDown() {
    let watcher = ClaudeCodeTranscriptWatcher(
      projectsDirectory: URL(fileURLWithPath: "/nowhere", isDirectory: true),
      pollInterval: .milliseconds(500), briskPeriod: .seconds(30), slowestInterval: .seconds(5))

    #expect(watcher.interval(after: .seconds(0)) == .milliseconds(500))
    #expect(watcher.interval(after: .seconds(29)) == .milliseconds(500))
    #expect(watcher.interval(after: .seconds(30)) == .seconds(1))
    #expect(watcher.interval(after: .seconds(60)) == .seconds(2))
    #expect(watcher.interval(after: .seconds(90)) == .seconds(4))
    #expect(watcher.interval(after: .seconds(120)) == .seconds(5))
    #expect(watcher.interval(after: .seconds(12 * 3600)) == .seconds(5))
  }

  @Test("A missing projects directory is simply no conversation yet")
  func missingDirectoryIsNotAnError() async {
    let watcher = ClaudeCodeTranscriptWatcher(
      projectsDirectory: URL(fileURLWithPath: "/nowhere/claude/projects", isDirectory: true),
      pollInterval: .milliseconds(20)
    )
    #expect(
      await watcher.awaitTranscript(identifier: identifier, timeout: .milliseconds(60)) == false)
  }
}
