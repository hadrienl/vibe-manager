import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

private actor CaptureRepository: SessionRepository {
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

private struct StubDiscovery: CodexSessionDiscovering {
  var identifier: String?
  var delay: Duration = .zero

  func discoverSessionIdentifier(
    workingDirectoryPath: String,
    since: Date,
    timeout: Duration
  ) async -> String? {
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    return identifier
  }
}

private func codexSession() -> WorkSession {
  WorkSession(
    name: "Refonte du parseur",
    agent: SessionAgentConfiguration(providerID: "codex", modelID: "gpt-6-astra")
  )
}

@Suite("Codex terminal identifier accumulator")
struct CodexTerminalIdentifierAccumulatorTests {
  private let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"

  @Test("An identifier split across two reads is reassembled")
  func reassemblesSplitIdentifier() async {
    let accumulator = CodexTerminalIdentifierAccumulator()

    #expect(await accumulator.consume("  session id: 019ee0a1-06d9") == nil)
    #expect(await accumulator.consume("-7e52-957b-d61a982d6b43\r\n") == identifier)
  }

  @Test("The label and its identifier may arrive in different reads")
  func reassemblesSplitLabel() async {
    let accumulator = CodexTerminalIdentifierAccumulator()

    #expect(await accumulator.consume("Sess") == nil)
    #expect(await accumulator.consume("ion \(identifier)\n") == identifier)
  }

  @Test("Only the first identifier of a launch is reported")
  func reportsOnce() async {
    let accumulator = CodexTerminalIdentifierAccumulator()

    #expect(await accumulator.consume("session id: \(identifier)\n") == identifier)
    #expect(await accumulator.consume("session id: 019ee0a1-9999-7e52-957b-d61a982d6b43\n") == nil)
    #expect(await accumulator.identifier == identifier)
  }

  @Test("A long line without an identifier does not grow without bound")
  func boundedTail() async {
    let accumulator = CodexTerminalIdentifierAccumulator()
    let noise = String(repeating: "x", count: 64 * 1024)

    #expect(await accumulator.consume(noise) == nil)
    #expect(await accumulator.consume(" session \(identifier)\n") == identifier)
  }
}

@Suite("Codex session identifier capture")
struct CodexSessionIdentifierCaptureTests {
  private let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"

  private func capture(
    session: WorkSession,
    repository: CaptureRepository,
    discovery: StubDiscovery
  ) -> CodexSessionIdentifierCapture {
    CodexSessionIdentifierCapture(
      sessionID: session.id,
      workingDirectoryPath: "/Users/test/app",
      discovery: discovery,
      record: RecordAgentResumeIdentifier(repository: repository),
      timeout: .milliseconds(200)
    )
  }

  @Test("The rollout identifier is stored on the work session")
  func storesRolloutIdentifier() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = capture(
      session: session,
      repository: repository,
      discovery: StubDiscovery(identifier: identifier)
    )

    await capture.start()
    try await waitUntil { await capture.identifier != nil }
    await capture.stop()

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("Terminal output can provide the identifier before the rollout appears")
  func storesTerminalIdentifier() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = capture(
      session: session,
      repository: repository,
      // A rollout that never appears within the timeout.
      discovery: StubDiscovery(identifier: nil)
    )

    await capture.start()
    await capture.observe(output: "  Session ID: \(identifier)\r\n")
    await capture.stop()

    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("The first source wins for the whole launch")
  func firstSourceWins() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = capture(
      session: session,
      repository: repository,
      discovery: StubDiscovery(
        identifier: "019ee0a1-9999-7e52-957b-d61a982d6b43", delay: .milliseconds(50))
    )

    await capture.start()
    await capture.observe(output: "session id: \(identifier)\n")
    try await Task.sleep(for: .milliseconds(120))
    await capture.stop()

    // The screen answered first; the rollout must not overwrite it afterwards.
    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await repository.saveCount == 1)
  }

  @Test("A session that never reveals an identifier stays unchanged")
  func noIdentifier() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = capture(
      session: session,
      repository: repository,
      discovery: StubDiscovery(identifier: nil)
    )

    await capture.start()
    await capture.observe(output: "Ready.\r\nWorking…\r\n")
    try await Task.sleep(for: .milliseconds(250))
    await capture.stop()

    #expect(await capture.identifier == nil)
    #expect(await repository.saveCount == 0)
  }

  @Test("Stopping the capture ends its rollout watch")
  func stopEndsWatch() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = capture(
      session: session,
      repository: repository,
      discovery: StubDiscovery(identifier: identifier, delay: .milliseconds(200))
    )

    await capture.start()
    await capture.stop()
    try await Task.sleep(for: .milliseconds(300))

    #expect(await capture.identifier == nil)
    #expect(await repository.saveCount == 0)
  }

  @Test("An identifier found before the session carries its agent is kept, not dropped")
  func retriesUntilTheSessionCanCarryIt() async throws {
    // The rollout file can appear before the creation flow has attached the agent
    // configuration: a single failed write would make this session unresumable for good.
    let session = WorkSession(name: "Refonte du parseur")
    let repository = CaptureRepository(stored: session)
    let capture = CodexSessionIdentifierCapture(
      sessionID: session.id,
      workingDirectoryPath: "/Users/test/app",
      discovery: StubDiscovery(identifier: identifier),
      record: RecordAgentResumeIdentifier(repository: repository),
      timeout: .milliseconds(200),
      persistenceWindow: .seconds(2),
      retryInterval: .milliseconds(10)
    )

    await capture.start()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await capture.identifier == nil)
    #expect(await repository.session(id: session.id)?.agent == nil)

    var ready = session
    ready.agent = SessionAgentConfiguration(providerID: "codex", modelID: "gpt-6-astra")
    await repository.save(ready)

    try await waitUntil { await capture.identifier == identifier }
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await capture.unstoredIdentifier == nil)
  }

  @Test("A read arriving while another is being accumulated is not consumed out of order")
  func keepsTerminalOutputOrdered() async throws {
    // The pseudo terminal cuts wherever the kernel buffer ended, and its reader hands each
    // read over without waiting for the previous one: consuming the second half first would
    // splice the wrong halves and lose the identifier for the whole launch.
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let gate = Gate()
    let capture = CodexSessionIdentifierCapture(
      sessionID: session.id,
      workingDirectoryPath: "/Users/test/app",
      discovery: StubDiscovery(identifier: nil),
      record: RecordAgentResumeIdentifier(repository: repository),
      accumulator: CodexTerminalIdentifierAccumulator(willConsume: { await gate.wait() }),
      timeout: .milliseconds(50)
    )

    // The first read is held inside the accumulator…
    let first = Task { await capture.observe(output: "  session id: 019ee0a1-06d9") }
    try await waitUntil { await gate.isWaiting }
    // …while the second arrives and finds the capture busy.
    let second = Task { await capture.observe(output: "-7e52-957b-d61a982d6b43\r\n") }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()

    _ = await (first.value, second.value)
    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("An identifier that can never be stored is reported, not swallowed")
  func reportsAnIdentifierItCouldNotStore() async throws {
    let session = WorkSession(name: "Refonte du parseur")
    let repository = CaptureRepository(stored: session)
    let capture = CodexSessionIdentifierCapture(
      sessionID: session.id,
      workingDirectoryPath: "/Users/test/app",
      discovery: StubDiscovery(identifier: nil),
      record: RecordAgentResumeIdentifier(repository: repository),
      timeout: .milliseconds(50),
      persistenceWindow: .milliseconds(100),
      retryInterval: .milliseconds(10)
    )

    await capture.start()
    await capture.observe(output: "session id: \(identifier)\n")
    _ = await capture.settled()

    #expect(await capture.identifier == nil)
    #expect(await capture.unstoredIdentifier == identifier)
  }
}

/// Holds the first consumption until the test lets it through, and reports when it is held.
private actor Gate {
  private var opened = false
  private(set) var isWaiting = false

  func open() {
    opened = true
  }

  func wait() async {
    guard !opened, !isWaiting else { return }
    isWaiting = true
    while !opened {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

/// Polls a condition instead of sleeping for a fixed time, so the suite stays fast and does
/// not depend on how quickly a watcher task is scheduled.
private func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("The condition never became true")
}
