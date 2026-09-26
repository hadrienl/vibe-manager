import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A store that keeps the ranks it is given, and lists the sessions newest first.
private actor OrderRepository: SessionRepository {
  private var stored: [WorkSession]

  init(_ sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] {
    stored.sorted { $0.updatedAt > $1.updatedAt }
  }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    stored.removeAll { $0.id == session.id }
    stored.append(session)
  }

  func reorder(_ ranks: [SessionID: Int]) {
    for index in stored.indices {
      if let rank = ranks[stored[index].id] { stored[index].rank = rank }
    }
  }
}

@MainActor
@Suite("Rearranging the sidebar by hand")
struct SessionOrderModelTests {
  private let apiOne = WorkSession(
    name: "Api 1", status: .active, updatedAt: Date(timeIntervalSince1970: 100),
    repositories: [RepositoryContext(path: "/work/api")], rank: 0)
  private let webOne = WorkSession(
    name: "Web 1", status: .active, updatedAt: Date(timeIntervalSince1970: 400),
    repositories: [RepositoryContext(path: "/work/web")], rank: 1)
  private let apiTwo = WorkSession(
    name: "Api 2", status: .active, updatedAt: Date(timeIntervalSince1970: 300),
    repositories: [RepositoryContext(path: "/work/api")], rank: 2)
  private let webTwo = WorkSession(
    name: "Web 2", status: .active, updatedAt: Date(timeIntervalSince1970: 200),
    repositories: [RepositoryContext(path: "/work/web")], rank: 3)

  private func makeModel(
    sort: SessionSort = .manual, mode: SidebarMode = .flat
  ) async -> AppModel {
    let layout = WorkspaceLayout(
      sessionFilter: SessionFilter(column: .doing, sort: sort), sidebarMode: mode)
    let model = AppModel(
      repository: OrderRepository([apiOne, webOne, apiTwo, webTwo]),
      layout: WorkspaceLayoutController(
        store: RecordingLayoutStore(layout: layout), saveDelay: .zero))
    await model.load()
    return model
  }

  @Test("Only the Manual sort, with nothing narrowing the list, can be rearranged")
  func onlyInManualSort() async {
    let model = await makeModel(sort: .lastActivity)
    #expect(!model.canReorder)
    #expect(!model.canMove(webTwo.id, by: -1))
    #expect(model.reorderUnavailableReason != nil)
    await model.move(webTwo.id, by: -1)
    #expect(model.displayedSessions.map(\.name) == ["Web 1", "Api 2", "Web 2", "Api 1"])

    model.setSort(.manual)
    #expect(model.canReorder)
    model.setSearchText("Api")
    #expect(!model.canReorder)
    #expect(!model.canMove(apiTwo.id, by: -1))
  }

  @Test("A session moves anywhere in the flat list, and keeps the selection")
  func flat() async {
    let model = await makeModel()
    model.select(webTwo.id)

    await model.move(webTwo.id, toIndex: 0)
    #expect(model.displayedSessions.map(\.name) == ["Web 2", "Api 1", "Web 1", "Api 2"])
    await model.move(webTwo.id, by: 1)
    #expect(model.displayedSessions.map(\.name) == ["Api 1", "Web 2", "Web 1", "Api 2"])
    #expect(model.selectedSessionID == webTwo.id)
    #expect(!model.canMove(model.displayedSessions[0].id, by: -1))
    #expect(!model.canMove(apiTwo.id, by: 1))
  }

  @Test("Grouped, a session never leaves its group, and the flat list follows")
  func grouped() async {
    let model = await makeModel(mode: .byFolder)
    #expect(model.displayedSessions.map(\.name) == ["Api 1", "Api 2", "Web 1", "Web 2"])

    #expect(!model.canMove(apiOne.id, by: -1))
    #expect(!model.canMove(apiTwo.id, by: 1))
    #expect(!model.canMove(webOne.id, by: -1))
    // An index past the group is clamped to its end, never into the next group.
    await model.move(apiOne.id, toIndex: 5)
    #expect(model.displayedSessions.map(\.name) == ["Api 2", "Api 1", "Web 1", "Web 2"])

    model.setSidebarMode(.flat)
    #expect(model.displayedSessions.map(\.name) == ["Api 2", "Web 1", "Api 1", "Web 2"])
  }

  @Test("A group moves as a block, and the flat list shows its sessions together")
  func groupMove() async throws {
    let model = await makeModel(mode: .byFolder)
    let web = try #require(model.groups.last)

    #expect(model.canMoveGroup(web, by: -1))
    #expect(!model.canMoveGroup(web, by: 1))
    await model.moveGroup(web, by: -1)
    #expect(model.groups.map(\.folderName) == ["web", "api"])

    model.setSidebarMode(.flat)
    #expect(model.displayedSessions.map(\.name) == ["Web 1", "Web 2", "Api 1", "Api 2"])
  }

  @Test("⌘1…⌘9 number the rows in their new order")
  func positionsFollow() async {
    let model = await makeModel()
    await model.move(webTwo.id, toIndex: 0)

    model.select(position: 1)
    #expect(model.selectedSessionID == webTwo.id)
  }

  @Test("Show Archived Sessions opens the list, and the sidebar with it")
  func archiveCommand() async {
    let model = await makeModel()
    model.layout.setSidebarVisible(false)

    model.showArchivedSessions()

    // The popover waits for its anchor: the sidebar is only being shown.
    #expect(!model.isArchiveListPresented)
    #expect(model.layout.intent.isSidebarVisible)

    model.presentPendingArchiveList()
    #expect(model.isArchiveListPresented)
    #expect(!model.isArchiveListPending)
  }

  @Test("Show Archived Sessions opens the list at once when the sidebar is there")
  func archiveCommandWithSidebar() async {
    let model = await makeModel()
    model.layout.setSidebarVisible(true)

    model.showArchivedSessions()

    #expect(model.isArchiveListPresented)
    #expect(!model.isArchiveListPending)
  }
}
