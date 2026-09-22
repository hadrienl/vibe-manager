import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Finding the session the user left open")
struct WorkspaceSelectionTests {
  @Test("The session selected last time is selected again")
  func restoresTheSelection() async {
    let first = WorkSession(name: "First", updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(name: "Second", updatedAt: Date(timeIntervalSince1970: 100))
    let store = RecordingLayoutStore(layout: WorkspaceLayout(selectedSessionID: second.id))
    let model = AppModel(
      repository: StubRepository(sessions: [first, second]),
      layout: WorkspaceLayoutController(store: store)
    )

    await model.load()

    #expect(model.selectedSessionID == second.id)
  }

  @Test("A stored selection that no longer exists does not block the launch")
  func missingSelectionFallsBack() async {
    let listed = WorkSession(name: "Still here", status: .active)
    let store = RecordingLayoutStore(layout: WorkspaceLayout(selectedSessionID: SessionID()))
    let model = AppModel(
      repository: StubRepository(sessions: [listed]),
      layout: WorkspaceLayoutController(store: store)
    )

    await model.load()

    #expect(model.selectedSessionID == listed.id)
    #expect(model.sessions.count == 1)
  }

  @Test("An empty store leaves nothing selected rather than failing")
  func emptyStoreSelectsNothing() async {
    let store = RecordingLayoutStore(layout: WorkspaceLayout(selectedSessionID: SessionID()))
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: store)
    )

    await model.load()

    #expect(model.selectedSessionID == nil)
  }

  @Test("A refresh that comes back empty does not cost the user their place")
  func transientlyEmptyRefreshKeepsTheSelection() async {
    let first = WorkSession(name: "First", updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(name: "Second", updatedAt: Date(timeIntervalSince1970: 100))
    let repository = StubRepository(sessions: [first, second])
    let store = RecordingLayoutStore(layout: WorkspaceLayout(selectedSessionID: second.id))
    let model = AppModel(repository: repository, layout: WorkspaceLayoutController(store: store))
    await model.load()
    #expect(model.selectedSessionID == second.id)

    // A store caught mid-write: the list is momentarily gone, the selection is not a decision
    // the user made to leave it.
    await repository.replace(with: [])
    await model.reload()
    #expect(model.selectedSessionID == second.id)

    await repository.replace(with: [first, second])
    await model.reload()
    #expect(model.selectedSessionID == second.id)
  }

  @Test("Selecting from the sidebar is what gets stored")
  func selectionIsStored() async {
    let first = WorkSession(name: "First", updatedAt: Date(timeIntervalSince1970: 200))
    let second = WorkSession(name: "Second", updatedAt: Date(timeIntervalSince1970: 100))
    let store = RecordingLayoutStore()
    let model = AppModel(
      repository: StubRepository(sessions: [first, second]),
      layout: WorkspaceLayoutController(store: store)
    )
    await model.load()

    model.select(second.id)
    await model.layout.flush()

    await #expect(store.load().selectedSessionID == second.id)
  }

  @Test("The shortcuts walk the sidebar in the order it is drawn, and stop at its ends")
  func keyboardNavigationWalksTheList() async {
    let first = WorkSession(
      name: "First", status: .active, updatedAt: Date(timeIntervalSince1970: 300))
    let second = WorkSession(
      name: "Second", status: .active, updatedAt: Date(timeIntervalSince1970: 200))
    let third = WorkSession(
      name: "Third", status: .active, updatedAt: Date(timeIntervalSince1970: 100))
    let model = AppModel(repository: StubRepository(sessions: [first, second, third]))
    await model.load()
    #expect(model.selectedSessionID == first.id)

    model.selectNext()
    #expect(model.selectedSessionID == second.id)

    model.selectPrevious()
    model.selectPrevious()
    #expect(model.selectedSessionID == first.id)

    model.select(position: 3)
    #expect(model.selectedSessionID == third.id)

    model.selectNext()
    #expect(model.selectedSessionID == third.id)

    // A position nobody is listed at changes nothing.
    model.select(position: 9)
    #expect(model.selectedSessionID == third.id)
  }
}

/// A store that simply hands back what it was built with, ordered as the repository contract asks.
private actor StubRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] {
    stored.sorted { lhs, rhs in
      if lhs.updatedAt == rhs.updatedAt {
        return lhs.id.description < rhs.id.description
      }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  func replace(with sessions: [WorkSession]) {
    stored = sessions
  }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}
