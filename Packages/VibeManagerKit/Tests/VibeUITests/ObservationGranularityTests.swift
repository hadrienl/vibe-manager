import Foundation
import Observation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// Whether a change reached a reader, as SwiftUI would be told of it.
private final class Flag: @unchecked Sendable {
  var isRaised = false
}

/// Reads as a view's `body` would, writes, and says whether that reader was told: the mechanism
/// SwiftUI evaluates a view again by, without a window.
@MainActor
private func notifies(reading read: () -> Void, when write: () -> Void) -> Bool {
  let flag = Flag()
  withObservationTracking(read) { flag.isRaised = true }
  write()
  return flag.isRaised
}

private struct NoTranscripts: SessionJournalReading {
  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) -> TranscriptReading {
    TranscriptReading(events: [], cursors: cursors, foundTranscript: false)
  }

  func transcriptDirectories(for session: WorkSession) -> [String] { [] }
}

private struct NoSummaries: SessionSummarizerResolving {
  func summarizer(for providerID: String) async -> (any SessionSummarizing)? { nil }
}

private struct NoRepositories: RepositoryIdentityResolving {
  func identity(ofDirectory path: String) async -> RepositoryIdentity? { nil }
}

/// #254: what one session does wakes the views of that session, and no other.
@MainActor
@Suite("Observation by session")
struct ObservationGranularityTests {
  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      taskStatus: .doing
    )
  }

  private func makeModel(_ sessions: [WorkSession]) async -> AppModel {
    let model = AppModel(
      repository: WorkspaceRepository(sessions: sessions),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    return model
  }

  private func working() -> AgentActivityState {
    var state = AgentActivityState(source: .structured)
    state.activity = .working
    return state
  }

  private func asking(_ id: SessionID, _ key: String) -> AgentActivityState {
    var state = AgentActivityState(source: .structured)
    state.activity = .awaitingUser(.approval)
    state.requests.append(
      AgentRequest(
        id: AgentRequestID(sessionID: id, key: key), receivedAt: Date(timeIntervalSince1970: 5),
        kind: .approval,
        content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: key)),
        reference: AgentToolReference(tool: "Bash", subject: key), isShown: true))
    return state
  }

  @Test("A cell tells its own reader, not the readers of the others, and never for the same value")
  func cells() {
    let cells = ObservedCells<Int, String>()
    #expect(!notifies(reading: { _ = cells.value(for: 1) }, when: { cells.set("b", for: 2) }))
    #expect(notifies(reading: { _ = cells.value(for: 1) }, when: { cells.set("a", for: 1) }))
    #expect(!notifies(reading: { _ = cells.value(for: 1) }, when: { cells.set("a", for: 1) }))
    #expect(cells.snapshot == [1: "a", 2: "b"])

    cells.replace(with: [2: "c"])
    #expect(cells.snapshot == [2: "c"])
  }

  @Test("Another session's activity wakes neither this session's state nor the window's count")
  func activityOfAnother() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(first.id)

    #expect(
      !notifies(reading: { _ = model.activity(for: first.id) }) {
        model.activityCells.set(working(), for: second.id)
      })
    #expect(
      !notifies(reading: { _ = model.statusPresentation(for: first) }) {
        model.activityCells.set(AgentActivityState(source: .structured), for: second.id)
      })
    #expect(
      !notifies(reading: { _ = model.pendingRequestCount }) {
        model.activityCells.set(working(), for: second.id)
        model.requestsDidChange()
      })
  }

  @Test("A session's own activity wakes its state: nothing is frozen")
  func activityOfItsOwn() async {
    let first = session("First")
    let model = await makeModel([first])

    #expect(
      notifies(reading: { _ = model.statusPresentation(for: first) }) {
        model.activityCells.set(working(), for: first.id)
      })
    #expect(model.activity(for: first.id)?.activity == .working)
    #expect(model.activities[first.id]?.activity == .working)
  }

  @Test("The count of requests waiting elsewhere follows requests and selection")
  func requestCount() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(first.id)
    #expect(model.pendingRequestCount == 0)

    #expect(
      notifies(reading: { _ = model.pendingRequestCount }) {
        model.activityCells.set(asking(second.id, "make"), for: second.id)
        model.requestsDidChange()
      })
    #expect(model.pendingRequestCount == 1)

    // On screen, the session answers its own requests: none waits elsewhere.
    model.select(second.id)
    #expect(model.pendingRequestCount == 0)
  }

  @Test("Another session's journal wakes neither this session's journal nor its summary's state")
  func journalOfAnother() {
    let journal = SessionJournalModel(
      monitor: SessionJournalMonitor(
        store: InMemorySessionJournalStore(), reader: NoTranscripts(),
        repositories: NoRepositories(), summarizers: NoSummaries()),
      preferences: InMemoryJournalPreferences(), opener: FakeOpener())
    let first = SessionID()
    let second = SessionID()

    #expect(
      !notifies(reading: { _ = journal.journal(for: first) }) {
        journal.summarizing.set(true, for: second)
      })
    #expect(
      !notifies(reading: { _ = journal.isSummarizing(first) }) {
        journal.summarizing.set(true, for: second)
      })
    #expect(
      notifies(reading: { _ = journal.isSummarizing(first) }) {
        journal.summarizing.set(true, for: first)
      })
    #expect(journal.isSummarizing(first))
  }
}
