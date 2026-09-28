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
  /// How long after the launch the rollout is written: a watch that ends sooner never sees it.
  var writtenAfter: Duration = .zero
  var looks: LookCounter? = nil
  /// Written after the watch looked for the last time before the end: only the look made as the
  /// process ends sees it.
  var onlyAtTheLastLook = false

  func discoverSessionIdentifier(for launch: CodexLaunch, timeout: Duration) async -> String? {
    await looks?.looked(timeout: timeout)
    if onlyAtTheLastLook {
      guard timeout == .zero else {
        try? await Task.sleep(for: timeout)
        return nil
      }
      return identifier
    }
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    return timeout >= writtenAfter ? identifier : nil
  }

  func release(_ identifier: String) async {
    await looks?.released(identifier)
  }
}

/// Every look the capture asked the discovery for, with how long it was allowed.
private actor LookCounter {
  private(set) var timeouts: [Duration] = []
  private(set) var releases: [String] = []

  func looked(timeout: Duration) {
    timeouts.append(timeout)
  }

  func released(_ identifier: String) {
    releases.append(identifier)
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

@Suite("Codex session identifier capture", .timeLimit(.minutes(2)))
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
      // Far longer than the test: what is checked is the retry, not the window closing on a
      // runner slow enough to spend it before the session is ready.
      persistenceWindow: .seconds(60),
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
///
/// No deadline of its own: a loaded runner can delay a watcher task by more than any deadline
/// worth picking. A condition that never becomes true is caught by the suite's time limit, which
/// cancels the sleep.
private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
  while await !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// A Codex provider whose rollouts are looked for by `discovery`.
private func codexProvider(discovery: any CodexSessionDiscovering) -> CodexAgentProvider {
  let environment = ["PATH": "/usr/bin", "HOME": "/Users/test"]
  return CodexAgentProvider(
    base: CommandLineAgentProvider(
      descriptor: CodexAgentProvider.descriptor,
      specification: CodexAgentProvider.specification,
      models: [],
      argumentBuilder: CodexArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        locator: StubLocator(location: .notFound),
        probe: StubProcessProbe(),
        environment: environment,
        now: { Date(timeIntervalSince1970: 0) }
      ),
      environment: environment
    ),
    catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models_cache.json")),
    discovery: discovery
  )
}

/// A Codex session that begins with its process and is named only with the first message (#144).
@Suite("A Codex conversation named long after the launch", .timeLimit(.minutes(2)))
struct CodexLateConversationTests {
  private let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"
  private let other = "019ee0a1-9999-7e52-957b-d61a982d6b43"

  private func plan(hooks: Bool, arguments: [String] = ["-C", "/Users/test/app"])
    -> AgentLaunchPlan
  {
    AgentLaunchPlan(
      providerID: CodexAgentProvider.id, executablePath: "/usr/local/bin/codex",
      arguments: arguments,
      environment: hooks ? [AgentActivityHookCommand.environmentKey: "/data/s.log"] : [:],
      workingDirectoryPath: "/Users/test/app", promptDelivery: .none)
  }

  @Test("Without hooks, a rollout written ten minutes after the launch is still stored (#144)")
  func rolloutWrittenLongAfterTheLaunchIsStored() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let observer = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(
        discovery: StubDiscovery(identifier: identifier, writtenAfter: .seconds(600))))

    await observer.launched(plan: plan(hooks: false))

    try await waitUntil {
      await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier
    }
    await observer.finished()
  }

  @Test("With hooks, the session the agent names is stored, however late")
  func sessionNamedByTheHookIsStored() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let looks = LookCounter()
    let observer = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(discovery: StubDiscovery(identifier: nil, looks: looks)))

    await observer.launched(plan: plan(hooks: true), hooksApproved: true)
    // The rollout is looked for as it always was, as a net under hooks that would not run.
    try await waitUntil { await looks.timeouts == [CodexSessionIdentifierCapture.defaultTimeout] }
    await observer.conversationNamed(identifier)

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await observer.awaitedResumeIdentifier() == nil)
  }

  @Test("The session the hook names replaces the rollout another pane wrote")
  func hookReplacesWhatTheRolloutSuggested() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let looks = LookCounter()
    let capture = CodexSessionIdentifierCapture(
      sessionID: session.id, workingDirectoryPath: "/Users/test/app",
      discovery: StubDiscovery(identifier: other, looks: looks),
      record: RecordAgentResumeIdentifier(repository: repository))

    await capture.start()
    try await waitUntil { await capture.identifier == other }
    await capture.named(identifier)
    // The rollout it had taken is another launch's to find.
    #expect(await looks.releases == [other])

    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    // Nothing else may write over the agent's own word afterwards.
    await capture.observe(output: "session id: \(other)\n")
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("Hooks passed but not approved: the rollout is looked for as long as the process lives")
  func unapprovedHooksKeepTheLongWatch() async throws {
    let session = codexSession()
    let looks = LookCounter()
    let observer = CodexLaunchObserver(
      sessionID: session.id, repository: CaptureRepository(stored: session),
      provider: codexProvider(discovery: StubDiscovery(identifier: nil, looks: looks)))

    // Codex could not be asked, or the approval did not take: it may still be refused.
    await observer.launched(plan: plan(hooks: true), hooksApproved: false)

    try await waitUntil {
      await looks.timeouts == [CodexSessionIdentifierCapture.defaultWatchLimit]
    }
    await observer.finished()
  }

  @Test("A rollout written after the half minute, just before the agent quit, is stored at the end")
  func lastLookAfterTheWatchEnded() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codex-sessions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let capture = CodexSessionIdentifierCapture(
      sessionID: session.id, workingDirectoryPath: "/Users/test/app",
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: root, pollInterval: .milliseconds(10), claims: CodexSessionClaims()),
      record: RecordAgentResumeIdentifier(repository: repository),
      timeout: .milliseconds(20))
    let launchedAt = Date()
    await capture.start(launchedAt: launchedAt)
    try await waitUntil { await !capture.isWatchingRollouts }

    // The first message comes once the watch is over, and the agent quits before its hook is read.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = """
      {"type":"session_meta","payload":{"id":"\(identifier)","cwd":"/Users/test/app",\
      "timestamp":"\(formatter.string(from: launchedAt))"}}

      """
    try line.write(
      to: root.appendingPathComponent("rollout-late-\(identifier).jsonl"), atomically: true,
      encoding: .utf8)
    await capture.finish()

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A name not written yet is handed on, and written by the instance that adopts the agent")
  func unwrittenNameIsHandedOn() async throws {
    // The session is not ready to carry it yet: its agent configuration is still missing.
    let session = WorkSession(name: "Refonte du parseur")
    let repository = CaptureRepository(stored: session)
    let first = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(discovery: StubDiscovery(identifier: nil)))
    await first.launched(plan: plan(hooks: true))
    await first.conversationNamed(identifier)
    await first.finished()
    #expect(await first.awaitedResumeIdentifier() == identifier)

    var ready = session
    ready.agent = SessionAgentConfiguration(providerID: "codex", modelID: "gpt-6-astra")
    await repository.save(ready)
    let adopting = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(discovery: StubDiscovery(identifier: nil)))
    await adopting.adopted(awaitedResumeIdentifier: identifier)

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
    #expect(await adopting.awaitedResumeIdentifier() == nil)
  }

  @Test("A resumed conversation does not look for a rollout: a new one would be another pane's")
  func resumedConversationDoesNotDiscover() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let looks = LookCounter()
    let observer = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(discovery: StubDiscovery(identifier: other, looks: looks)))

    await observer.launched(
      plan: plan(hooks: false, arguments: ["resume", "-C", "/Users/test/app", "--", identifier]))
    await observer.finished()

    #expect(await looks.timeouts.isEmpty)
    #expect(await repository.saveCount == 0)
  }

  @Test("A rollout written just before the agent quit is stored when it ends")
  func rolloutWrittenJustBeforeTheEndIsStored() async throws {
    let session = codexSession()
    let repository = CaptureRepository(stored: session)
    let observer = CodexLaunchObserver(
      sessionID: session.id, repository: repository,
      provider: codexProvider(
        discovery: StubDiscovery(identifier: identifier, onlyAtTheLastLook: true)))

    await observer.launched(plan: plan(hooks: false))
    #expect(await repository.saveCount == 0)
    await observer.finished()

    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }
}
