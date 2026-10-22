import Foundation
import Testing

@testable import VibeDomain

@Suite("The history of a session's statuses (#406)")
struct SessionStatusHistoryTests {
  let start = Date(timeIntervalSince1970: 1_700_000_000)

  func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
  }

  func created() -> WorkSession {
    WorkSession(
      name: "Task", status: .closed, createdAt: start, updatedAt: start, closedAt: start,
      statusHistory: .created(in: .todo, at: start), infersStartedAt: false)
  }

  @Test("Each move is written where it happens, with its cause")
  func movesAreRecorded() throws {
    var session = created()
    try session.setTaskStatus(.doing, at: at(10), cause: .launch)
    try session.setTaskStatus(.done, at: at(20), cause: .user)
    try session.archive(at: at(30), cause: .rule(id: UUID(), name: "Red"))
    try session.restore(at: at(40), cause: .unarchive)

    let entries = session.statusHistory.entries
    #expect(entries.map(\.from) == [nil, .todo, .doing, .done, .archived])
    #expect(entries.map(\.to) == [.todo, .doing, .done, .archived, .done])
    #expect(entries.map(\.date) == [start, at(10), at(20), at(30), at(40)])
    #expect(entries.first?.cause == .created)
    #expect(session.statusHistory.lastEntryCause == .unarchive)
    try session.validate()
  }

  @Test("A status left as it was writes nothing")
  func unchangedStatusWritesNothing() throws {
    var session = created()
    try session.setTaskStatus(.todo, at: at(10), cause: .user)
    #expect(session.statusHistory.entries.count == 1)
  }

  @Test("Done counts from the last end, and reopening is counted")
  func readers() throws {
    var session = created()
    try session.setTaskStatus(.doing, at: at(10), cause: .launch)
    try session.setTaskStatus(.done, at: at(100), cause: .user)
    try session.setTaskStatus(.doing, at: at(200), cause: .launch)
    try session.setTaskStatus(.done, at: at(300), cause: .user)
    try session.archive(at: at(400), cause: .user)
    try session.restore(at: at(500), cause: .undo)

    let history = session.statusHistory
    #expect(history.enteredCurrentStatusAt == at(500))
    #expect(history.firstEntry(into: .done) == at(100))
    #expect(history.firstEntry(into: .waiting) == nil)
    // Archiving is not reopening.
    #expect(history.reopenCount == 1)
    #expect(history.timeSpent(in: .doing, until: at(1000)) == 190)
    #expect(history.timeSpent(in: .done, until: at(1000)) == 100 + 100 + 500)
  }

  @Test("Past the limit, the oldest go, except the creation")
  func limit() throws {
    var session = created()
    for index in 1...(SessionStatusHistory.limit + 10) {
      try session.setTaskStatus(index.isMultiple(of: 2) ? .todo : .doing, at: at(Double(index)), cause: .user)
    }
    let entries = session.statusHistory.entries
    #expect(entries.count == SessionStatusHistory.limit)
    #expect(entries.first?.cause == .created)
    #expect(entries.last?.date == at(Double(SessionStatusHistory.limit + 10)))
    try session.validate()
  }

  @Test("A history rebuilt from the lifecycle walks To Do, In Progress, then where it stands")
  func reconstruction() {
    let archived = WorkSession(
      name: "Old", status: .archived, createdAt: start, updatedAt: at(400), closedAt: at(300),
      archivedAt: at(400), startedAt: at(100))
    #expect(archived.statusHistory.entries.map(\.to) == [.todo, .doing, .done, .archived])
    #expect(archived.statusHistory.entries.map(\.date) == [start, at(100), at(300), at(400)])
    #expect(archived.statusHistory.entries.allSatisfy { $0.cause == .reconstructed })

    let waiting = WorkSession(
      name: "Waiting", status: .closed, createdAt: start, updatedAt: at(50), startedAt: at(10),
      taskStatus: .waiting)
    #expect(waiting.statusHistory.entries.map(\.to) == [.todo, .doing, .waiting])

    let planned = WorkSession(
      name: "Planned", status: .closed, createdAt: start, updatedAt: start,
      infersStartedAt: false)
    #expect(planned.statusHistory.entries.map(\.to) == [.todo])
  }

  @Test("A history that does not lead to the session's status is rebuilt rather than refused")
  func inconsistentHistoryIsRebuilt() throws {
    let wrong = SessionStatusHistory(entries: [
      SessionStatusChange(date: start, from: nil, to: .todo, cause: .created),
      SessionStatusChange(date: at(10), from: .doing, to: .done, cause: .user),
    ])
    let session = WorkSession(
      name: "Task", status: .closed, createdAt: start, updatedAt: at(10), startedAt: at(5),
      taskStatus: .done, statusHistory: wrong)
    #expect(session.statusHistory.entries.allSatisfy { $0.cause == .reconstructed })
    #expect(session.statusHistory.lastEntry?.to == .done)
    try session.validate()
  }

  @Test("Dates out of order, or a first entry that creates nothing, do not hold")
  func consistency() {
    let backwards = SessionStatusHistory(entries: [
      SessionStatusChange(date: at(10), from: nil, to: .todo, cause: .created),
      SessionStatusChange(date: start, from: .todo, to: .doing, cause: .user),
    ])
    #expect(!backwards.isConsistent(with: .doing))
    let headless = SessionStatusHistory(entries: [
      SessionStatusChange(date: start, from: .todo, to: .doing, cause: .user)
    ])
    #expect(!headless.isConsistent(with: .doing))
    #expect(!SessionStatusHistory(entries: []).isConsistent(with: .todo))
  }

  @Test("A drafted session starts with its creation")
  func draftCreatesHistory() {
    var draft = SessionDraft()
    draft.name = "New"
    let session = draft.session(createdAt: start)
    #expect(session.statusHistory.entries == [
      SessionStatusChange(date: start, from: nil, to: .todo, cause: .created)
    ])
  }
}
