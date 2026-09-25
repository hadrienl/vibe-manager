import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Hands each session the events the test queues, once, and moves its cursor.
actor QueuedJournalReader: SessionJournalReading {
  private var queued: [SessionID: [(String, TranscriptEvent)]] = [:]
  private(set) var readCount = 0

  func queue(_ id: SessionID, _ events: [TranscriptEvent], provider: String = "claude-code") {
    queued[id, default: []] += events.map { (provider, $0) }
  }

  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) -> TranscriptReading {
    readCount += 1
    let events = queued.removeValue(forKey: session.id) ?? []
    var cursors = cursors
    let path = "/t/\(session.id).jsonl"
    cursors[path, default: TranscriptCursor()].offset += UInt64(events.count)
    return TranscriptReading(events: events, cursors: cursors, foundTranscript: true)
  }

  func transcriptDirectories(for session: WorkSession) -> [String] { ["/t"] }
}

/// Answers with what the test says, and remembers what it was asked.
actor ScriptedSummarizer: SessionSummarizing, SessionSummarizerResolving {
  var answers: [Result<[SummaryEntry], SummaryError>] = []
  private(set) var requests: [SummaryRequest] = []
  private(set) var running = 0
  private(set) var mostRunning = 0
  var hold: Duration = .zero
  var supported: Set<String> = ["claude-code", "codex"]

  func setAnswers(_ answers: [Result<[SummaryEntry], SummaryError>]) { self.answers = answers }
  func setHold(_ hold: Duration) { self.hold = hold }

  func summarizer(for providerID: String) -> (any SessionSummarizing)? {
    supported.contains(providerID) ? self : nil
  }

  func summarize(_ request: SummaryRequest) async throws -> [SummaryEntry] {
    requests.append(request)
    running += 1
    mostRunning = max(mostRunning, running)
    defer { running -= 1 }
    if hold > .zero { try await Task.sleep(for: hold) }
    let answer =
      answers.isEmpty ? .success([SummaryEntry(text: "Did it", turn: 1)]) : answers.removeFirst()
    return try answer.get()
  }
}

struct NoRepositories: RepositoryIdentityResolving {
  func identity(ofDirectory path: String) async -> RepositoryIdentity? { nil }
}

@Suite("Keeping the journal of every active session")
struct SessionJournalMonitorTests {
  private let fast = SessionJournalMonitor.Timing(
    quiet: .milliseconds(50), minimumInterval: .milliseconds(50),
    retries: [.milliseconds(50)], readDelay: .milliseconds(10), saveDelay: .milliseconds(10))

  private func session(_ provider: String = "claude-code", status: SessionStatus = .active)
    -> WorkSession
  {
    WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: provider, resumeIdentifier: "abc"),
      status: status)
  }

  private func turn(_ prompt: String) -> [TranscriptEvent] {
    [
      .prompt(prompt, at: nil),
      .toolCall(
        TranscriptToolCall(name: "Bash", command: "git status", summary: "Bash: git status")),
      .agentText("Done.", at: nil),
      .turnEnded(at: Date()),
    ]
  }

  private func make(
    reader: QueuedJournalReader, summarizer: ScriptedSummarizer,
    store: InMemorySessionJournalStore = InMemorySessionJournalStore(),
    events: ManualFileChanges? = nil, timing: SessionJournalMonitor.Timing? = nil,
    concurrent: Int = 2
  ) -> SessionJournalMonitor {
    SessionJournalMonitor(
      store: store, reader: reader, repositories: NoRepositories(), summarizers: summarizer,
      events: events, timing: timing ?? fast, maximumConcurrentPasses: concurrent,
      language: "fr-FR")
  }

  @Test("A turn that ends is summarized, without anyone asking, and the entry dated by its turn")
  func summarizesAfterTurn() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let store = InMemorySessionJournalStore()
    let monitor = make(reader: reader, summarizer: summarizer, store: store)
    let session = session()
    await reader.queue(session.id, turn("Review https://github.com/o/r/pull/3"))
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.entries.count == 1 })
    let journal = try #require(await monitor.journal(for: session.id))
    #expect(journal.entries.first?.text == "Did it")
    #expect(journal.pending.isEmpty)
    #expect(journal.resources.map(\.label) == ["#3"])
    let request = try #require(await summarizer.requests.first)
    #expect(request.language == "fr-FR")
    #expect(request.digest.contains("Bash: git status"))
    #expect(request.digest.contains("https://github.com/o/r/pull/3"))
    #expect(await eventually { await store.journal(for: session.id)?.entries.count == 1 })
    await monitor.stop()
  }

  @Test("Resources are listed during the turn, without waiting for its end")
  func resourcesBeforeTurnEnds() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let monitor = make(reader: reader, summarizer: summarizer)
    let session = session()
    await reader.queue(session.id, [.prompt("see https://gitlab.com/g/p/-/issues/4", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(await summarizer.requests.isEmpty)
    await monitor.stop()
  }

  @Test("A failed pass adds nothing, keeps the turns, says so, and is tried again")
  func failureKeepsTurns() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    await summarizer.setAnswers([.failure(.failed("boom"))])
    let monitor = make(reader: reader, summarizer: summarizer)
    let session = session()
    await reader.queue(session.id, turn("fix"))
    await monitor.track([session])
    #expect(
      await eventually {
        if case .failed = await monitor.journal(for: session.id)?.summary { return true }
        return false
      })
    #expect(await monitor.journal(for: session.id)?.pending.count == 1)
    #expect(await monitor.journal(for: session.id)?.entries.isEmpty == true)
    // The retry succeeds, with the same turn.
    #expect(await eventually { await monitor.journal(for: session.id)?.entries.count == 1 })
    #expect(await monitor.journal(for: session.id)?.summary == .ready)
    await monitor.stop()
  }

  @Test("An agent that cannot summarize is said so, and the resources are still read")
  func unsupported() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let monitor = make(reader: reader, summarizer: summarizer)
    let session = session("mock")
    await reader.queue(
      session.id, [.prompt("https://github.com/o/r/issues/1", at: nil)] + turn("x"))
    await monitor.track([session])
    #expect(
      await eventually {
        await monitor.journal(for: session.id)?.summary == .unavailable(.unsupported)
      })
    #expect(await monitor.journal(for: session.id)?.resources.count == 1)
    await monitor.stop()
  }

  @Test("Turns that end close together make one pass, and passes are spaced by the interval")
  func grouping() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let timing = SessionJournalMonitor.Timing(
      quiet: .milliseconds(100), minimumInterval: .seconds(60), retries: [],
      readDelay: .milliseconds(10), saveDelay: .milliseconds(10))
    let monitor = make(reader: reader, summarizer: summarizer, timing: timing)
    let session = session()
    await reader.queue(session.id, turn("one") + turn("two"))
    await monitor.track([session])
    #expect(await eventually { await summarizer.requests.count == 1 })
    #expect(await summarizer.requests.first?.turnCount == 2)
    await reader.queue(session.id, turn("three"))
    await monitor.refresh()
    try await Task.sleep(for: .milliseconds(400))
    #expect(await summarizer.requests.count == 1)
    #expect(await monitor.journal(for: session.id)?.pending.count == 1)
    await monitor.stop()
  }

  @Test("At most two passes at once in the whole application")
  func concurrency() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    await summarizer.setHold(.milliseconds(200))
    let monitor = make(reader: reader, summarizer: summarizer)
    let sessions = (0..<4).map { _ in session() }
    for session in sessions { await reader.queue(session.id, turn("go")) }
    await monitor.track(sessions)
    #expect(await eventually { await summarizer.requests.count == 4 })
    #expect(await summarizer.mostRunning == 2)
    await monitor.stop()
  }

  @Test("A session that stops is summarized one last time, its unfinished turn included")
  func finalPass() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let store = InMemorySessionJournalStore()
    let timing = SessionJournalMonitor.Timing(
      quiet: .seconds(60), minimumInterval: .seconds(60), retries: [],
      readDelay: .milliseconds(10), saveDelay: .seconds(60))
    let monitor = make(reader: reader, summarizer: summarizer, store: store, timing: timing)
    let session = session()
    await reader.queue(session.id, [.prompt("half done", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await reader.readCount >= 1 })
    let closed = WorkSession(
      id: session.id, name: "S", agent: session.agent, status: .closed, createdAt: session.createdAt
    )
    await monitor.track([closed])
    #expect(await eventually { await store.journal(for: session.id)?.entries.count == 1 })
    #expect(await summarizer.requests.first?.digest.contains("half done") == true)
    await monitor.stop()
  }

  @Test("A session restarted while its last pass runs stays followed")
  func restartedWhileFinishing() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    await summarizer.setHold(.milliseconds(300))
    let monitor = make(reader: reader, summarizer: summarizer)
    let session = session()
    await reader.queue(session.id, [.prompt("half done", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await reader.readCount >= 1 })
    let closed = WorkSession(
      id: session.id, name: "S", agent: session.agent, status: .closed,
      createdAt: session.createdAt)
    await monitor.track([closed])
    #expect(await eventually { await summarizer.requests.count == 1 })
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.entries.count == 1 })
    await reader.queue(session.id, [.prompt("https://github.com/o/r/issues/5", at: nil)])
    await monitor.refresh()
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }

  @Test("The journal is found again by a new monitor: nothing read twice, nothing lost")
  func relaunch() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let store = InMemorySessionJournalStore()
    let session = session()
    let first = make(reader: reader, summarizer: summarizer, store: store)
    await reader.queue(session.id, turn("x"))
    await first.track([session])
    #expect(await eventually { await first.journal(for: session.id)?.entries.count == 1 })
    await first.stop()
    let second = make(reader: reader, summarizer: summarizer, store: store)
    await second.track([session])
    let journal = await second.journal(for: session.id)
    #expect(journal?.entries.count == 1)
    #expect(journal?.cursors["/t/\(session.id).jsonl"]?.offset == 4)
    await second.stop()
  }

  @Test("Off, no pass starts; turned back on, the waiting turns are summarized")
  func disabled() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let monitor = make(reader: reader, summarizer: summarizer)
    await monitor.setSummariesEnabled(false)
    let session = session()
    await reader.queue(session.id, turn("x"))
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.hasEndedTurn == true })
    try await Task.sleep(for: .milliseconds(200))
    #expect(await summarizer.requests.isEmpty)
    await monitor.setSummariesEnabled(true)
    #expect(await eventually { await summarizer.requests.count == 1 })
    await monitor.stop()
  }

  @Test("A transcript that moved is read for the session it belongs to")
  func watch() async throws {
    let reader = QueuedJournalReader()
    let summarizer = ScriptedSummarizer()
    let events = ManualFileChanges()
    let monitor = make(reader: reader, summarizer: summarizer, events: events)
    let session = session()
    await monitor.track([session])
    #expect(await eventually { events.watchedPaths == ["/t"] })
    #expect(await eventually { await reader.readCount >= 1 })
    let before = await reader.readCount
    await reader.queue(session.id, [.prompt("https://github.com/o/r/issues/8", at: nil)])
    events.send(.changed(["/t/other.jsonl"]))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await reader.readCount == before)
    events.send(.changed(["/t/x/abc.jsonl"]))
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }
}
