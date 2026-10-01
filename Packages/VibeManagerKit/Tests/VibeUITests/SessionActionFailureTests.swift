import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("An action that fails says which, on which session, and runs again (#244)")
struct SessionActionFailureTests {
  @Test("A status change the store refuses names the session, and Try Again runs it again")
  func failedStatusChange() async throws {
    let session = WorkSession(name: "Refactor the parser", taskStatus: .todo)
    let repository = WriteFailingRepository(sessions: [session])
    let model = AppModel(repository: repository)
    await model.reload()
    await repository.refuseWrites(true)

    await model.setTaskStatus(.waiting, for: session.id)

    let message = try #require(model.actionFailure?.message)
    #expect(message.contains("Refactor the parser"))
    #expect(!message.contains("Unable to load work sessions"))
    #expect(model.refreshFailure == nil)
    #expect(model.sessions.map(\.id) == [session.id])

    await repository.refuseWrites(false)
    await model.retryActionFailure()

    #expect(model.actionFailure == nil)
    #expect(model.sessions.first?.taskStatus == .waiting)
  }

  @Test("The reload that follows a failed action keeps its banner, and never blanks the screen")
  func failedOrderSurvivesTheReload() async throws {
    let first = WorkSession(name: "First", taskStatus: .todo)
    let second = WorkSession(name: "Second", taskStatus: .todo)
    let repository = WriteFailingRepository(sessions: [first, second])
    let model = AppModel(repository: repository)
    await model.reload()
    await repository.refuseWrites(true)

    // Reloads after the failed write: the store reads fine, the order was not saved.
    await model.commitOrder([second, first])

    #expect(model.actionFailure != nil)
    #expect(model.refreshFailure == nil)
    guard case .loaded = model.state else {
      Issue.record("expected the sessions on screen, got \(model.state)")
      return
    }

    model.dismissActionFailure()
    #expect(model.actionFailure == nil)
  }
}

/// A store that reads, and refuses every write while told to.
private actor WriteFailingRepository: SessionRepository {
  private var stored: [WorkSession]
  private var refusesWrites = false

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func refuseWrites(_ refuses: Bool) { refusesWrites = refuses }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) throws {
    if refusesWrites { throw WriteRefused() }
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private struct WriteRefused: Error {}
