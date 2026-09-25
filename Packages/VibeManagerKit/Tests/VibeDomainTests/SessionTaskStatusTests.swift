import Foundation
import Testing

@testable import VibeDomain

@Suite("A session's task status")
struct SessionTaskStatusTests {
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func session(_ status: SessionStatus, started: Bool = true) -> WorkSession {
    WorkSession(
      name: "Task",
      status: status,
      createdAt: date,
      updatedAt: date,
      closedAt: status == .active ? nil : date,
      archivedAt: status == .archived ? date : nil,
      startedAt: started ? date : nil
    )
  }

  @Test(
    "A swipe offers the statuses on each side, nearest first, and Archive only from Done",
    arguments: [
      (SessionTaskStatus.todo, [SessionTaskStatus](), [SessionTaskStatus.doing, .waiting, .done]),
      (.doing, [.todo], [.waiting, .done]),
      (.waiting, [.doing, .todo], [.done]),
      (.done, [.waiting, .doing, .todo], [.archived]),
      (.archived, [], []),
    ])
  func neighbours(
    status: SessionTaskStatus, previous: [SessionTaskStatus], next: [SessionTaskStatus]
  ) {
    #expect(status.previous == previous)
    #expect(status.next == next)
  }

  @Test("A session stored before the status existed reads it from its lifecycle")
  func inferredFromTheLifecycle() {
    #expect(session(.active).taskStatus == .doing)
    #expect(session(.closed, started: false).taskStatus == .todo)
    #expect(session(.closed).taskStatus == .done)
    #expect(session(.archived).taskStatus == .archived)
  }

  @Test("Moving between columns leaves the process alone and touches the session")
  func movingTouchesOnly() throws {
    var subject = session(.active)
    try subject.setTaskStatus(.waiting, at: date.addingTimeInterval(60))

    #expect(subject.taskStatus == .waiting)
    #expect(subject.status == .active)
    #expect(subject.updatedAt == date.addingTimeInterval(60))
    try subject.validate()
  }

  @Test("Archiving and unarchiving are not status changes")
  func archivedGoesThroughTheLifecycle() throws {
    var subject = session(.closed)
    #expect(throws: SessionTaskStatusError.requiresLifecycleChange(from: .done, to: .archived)) {
      try subject.setTaskStatus(.archived, at: date)
    }

    try subject.archive(at: date.addingTimeInterval(10))
    #expect(subject.taskStatus == .archived)
    #expect(throws: SessionTaskStatusError.requiresLifecycleChange(from: .archived, to: .todo)) {
      try subject.setTaskStatus(.todo, at: date.addingTimeInterval(20))
    }

    try subject.restore(at: date.addingTimeInterval(30))
    #expect(subject.taskStatus == .done)
    #expect(subject.status == .closed)
  }

  @Test("Closing and reopening the agent keep the status")
  func processDoesNotMoveTheTask() throws {
    var subject = session(.active)
    try subject.setTaskStatus(.waiting, at: date)
    try subject.close(at: date.addingTimeInterval(10))
    #expect(subject.taskStatus == .waiting)
    try subject.reopen(at: date.addingTimeInterval(20))
    #expect(subject.taskStatus == .waiting)
  }

  @Test("A session archived on one axis only is invalid")
  func invariantIsValidated() {
    let halfArchived = WorkSession(
      name: "Half", status: .closed, createdAt: date, updatedAt: date, closedAt: date,
      startedAt: date, taskStatus: .archived)
    #expect(throws: WorkSessionValidationError.invalidTaskStatus) { try halfArchived.validate() }
  }
}
