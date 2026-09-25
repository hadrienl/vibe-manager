import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private actor TaskSessionRepository: SessionRepository {
  private var value: WorkSession

  init(value: WorkSession) {
    self.value = value
  }

  func sessions() -> [WorkSession] { [value] }
  func session(id: SessionID) -> WorkSession? { value.id == id ? value : nil }
  func save(_ session: WorkSession) { value = session }
}

private struct TaskClock: SessionClock {
  let value: Date
  func now() -> Date { value }
}

@Suite("Moving a session between columns")
struct ChangeTaskStatusTests {
  private let createdAt = Date(timeIntervalSince1970: 100)

  private func session(_ status: SessionStatus, started: Bool = true) -> WorkSession {
    WorkSession(
      name: "Task", status: status, createdAt: createdAt, updatedAt: createdAt,
      closedAt: status == .active ? nil : createdAt, startedAt: started ? createdAt : nil)
  }

  @Test("The status is written with the time of the move, and nothing else changes")
  func statusIsWritten() async throws {
    let subject = session(.active)
    let repository = TaskSessionRepository(value: subject)
    let change = ChangeTaskStatus(
      repository: repository, clock: TaskClock(value: Date(timeIntervalSince1970: 500)))

    let updated = try await change(id: subject.id, to: .waiting)

    #expect(updated.taskStatus == .waiting)
    #expect(updated.status == .active)
    #expect(updated.updatedAt == Date(timeIntervalSince1970: 500))
    #expect(await repository.session(id: subject.id) == updated)
  }

  @Test("A clock that stepped back does not strand the move")
  func clockRegressionIsClamped() async throws {
    let subject = session(.active)
    let change = ChangeTaskStatus(
      repository: TaskSessionRepository(value: subject), clock: TaskClock(value: .distantPast))

    let updated = try await change(id: subject.id, to: .todo)

    #expect(updated.taskStatus == .todo)
    #expect(updated.updatedAt == createdAt)
  }

  @Test("Archiving is refused on this path: it stops a process")
  func archivingIsRefused() async {
    let subject = session(.closed)
    let change = ChangeTaskStatus(repository: TaskSessionRepository(value: subject))

    await #expect(throws: SessionTaskStatusError.self) {
      try await change(id: subject.id, to: .archived)
    }
  }

  @Test(
    "Starting work moves To Do and Done In Progress, and leaves Waiting where it is",
    arguments: [
      (SessionTaskStatus.todo, SessionTaskStatus.doing),
      (.doing, .doing),
      (.waiting, .waiting),
      (.done, .doing),
    ])
  func beginWork(from status: SessionTaskStatus, to expected: SessionTaskStatus) async throws {
    var subject = session(.closed)
    if status != subject.taskStatus { try subject.setTaskStatus(status, at: createdAt) }
    let repository = TaskSessionRepository(value: subject)

    let updated = try await ChangeTaskStatus(repository: repository).beginWork(id: subject.id)

    #expect(updated?.taskStatus == expected)
  }

  @Test("An unknown session is reported, not created")
  func unknownSession() async {
    let change = ChangeTaskStatus(repository: TaskSessionRepository(value: session(.active)))
    let missing = SessionID()

    await #expect(throws: ChangeSessionStatusError.sessionNotFound(missing)) {
      try await change(id: missing, to: .done)
    }
  }
}
