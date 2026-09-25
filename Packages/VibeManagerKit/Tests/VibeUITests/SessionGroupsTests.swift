import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting
import VibeTerminalUI

@testable import VibeUI

private func presentation(
  _ activity: AgentActivity, unread: Bool = false, pane: TerminalPaneModel.Status = .running
) -> SessionStatusPresentation {
  SessionStatusPresentation.make(
    session: WorkSession(name: "Task", status: .active), paneStatus: pane,
    activity: AgentActivityState(
      activity: activity, unreadSince: unread ? Date() : nil, source: .structured))
}

private let question = presentation(.awaitingUser(.question))
private let approval = presentation(.awaitingUser(.approval))
private let unread = presentation(.idle, unread: true)
private let failed = presentation(.idle, pane: .exited(code: 1))
private let working = presentation(.working)
private let starting = presentation(.idle, pane: .starting)
private let idle = presentation(.idle)
private let closed = SessionStatusPresentation.make(
  session: WorkSession(name: "Done", status: .closed), paneStatus: nil)
private let unavailable = SessionStatusPresentation.make(
  session: WorkSession(name: "Gone", status: .closed), paneStatus: nil,
  resolution: .unknownProvider("gone"))

@Suite("What the header of a group says about its sessions")
struct SessionGroupStatusTests {
  @Test("The most pressing state wins, the agent's questions before a process error")
  func order() {
    let ranked = [question, approval, unread, failed, unavailable, working, starting, idle]
    for (index, expected) in ranked.enumerated() {
      let rest = Array(ranked[index...]) + [closed]
      #expect(SessionGroupStatus.aggregate(rest.reversed()).headline == expected)
    }
  }

  @Test("Each state alone is its own headline, with the symbol and words of its row")
  func eachAlone() {
    for status in [question, approval, unread, failed, unavailable, working, starting, idle] {
      let headline = SessionGroupStatus.aggregate([status, closed]).headline
      #expect(headline?.symbolName == status.symbolName)
      #expect(headline?.label == status.label)
    }
  }

  @Test("Closed and finished sessions have nothing to say")
  func nothingToSay() {
    #expect(SessionGroupStatus.aggregate([closed, closed]).headline == nil)
    #expect(SessionGroupStatus.aggregate([]).headline == nil)
  }

  @Test("An agent that went missing is not counted as waiting for the user")
  func unavailableIsNotAttention() {
    let summary = SessionGroupStatus.aggregate([unavailable, working])

    #expect(summary.needsAttentionCount == 0)
    #expect(summary.errorCount == 1)
    #expect(summary.headline == unavailable)
  }

  @Test("VoiceOver counts the states and says whether the group is folded, in both languages")
  func accessibilityLabel() {
    let group = SessionGroup(
      id: SessionFolderKey(path: "/work/vibe-manager"), folderName: "vibe-manager",
      displayPath: "/work/vibe-manager",
      sessions: [WorkSession(name: "A"), WorkSession(name: "B"), WorkSession(name: "C")])
    let summary = SessionGroupStatus.aggregate([question, working, closed])

    let label = SessionGroupStatus.accessibilityLabel(
      for: group, summary: summary, isExpanded: false, containsSelection: false)

    #expect(label == "vibe-manager, 3 sessions, 1 needs attention, 1 working, Collapsed")
    #expect(
      Localization.string("\(1) need attention", module: "VibeUI", in: "fr") == "1 action requise")
    #expect(Localization.string("\(2) working", module: "VibeUI", in: "fr") == "2 en cours")
  }
}

/// A store that hands back what it was built with, newest first.
private actor GroupsRepository: SessionRepository {
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
}

@MainActor
@Suite("The sidebar grouped by working folder")
struct SidebarGroupsTests {
  private let apiNew = WorkSession(
    name: "Api new", status: .active, updatedAt: Date(timeIntervalSince1970: 400),
    repositories: [RepositoryContext(path: "/work/api")])
  private let webNew = WorkSession(
    name: "Web new", status: .active, updatedAt: Date(timeIntervalSince1970: 300),
    repositories: [RepositoryContext(path: "/work/web")])
  private let apiOld = WorkSession(
    name: "Api old", status: .active, updatedAt: Date(timeIntervalSince1970: 200),
    repositories: [RepositoryContext(path: "/work/api")])
  private let webOld = WorkSession(
    name: "Web old", status: .active, updatedAt: Date(timeIntervalSince1970: 100),
    repositories: [RepositoryContext(path: "/work/web")])

  private func makeModel(
    layout: WorkspaceLayout = WorkspaceLayout(sidebarMode: .byFolder),
    store: RecordingLayoutStore? = nil,
    labels: [SessionFolderKey: String] = [:]
  ) async -> AppModel {
    let model = AppModel(
      repository: GroupsRepository([apiNew, webNew, apiOld, webOld]),
      layout: WorkspaceLayoutController(
        store: store ?? RecordingLayoutStore(layout: layout), saveDelay: .zero),
      folderLabels: InMemoryFolderLabelStore(labels: labels))
    await model.load()
    return model
  }

  @Test("The grouped view lists the same sessions as the flat one, group by group")
  func sameSessions() async {
    let model = await makeModel()

    #expect(model.displayedSessions.map(\.name) == ["Api new", "Api old", "Web new", "Web old"])
    model.setSidebarMode(.flat)
    #expect(model.displayedSessions.map(\.name) == ["Api new", "Web new", "Api old", "Web old"])
  }

  @Test("⌥⌘↓ and ⌘1…⌘9 follow the rows on screen and step over a folded group")
  func keyboardFollowsTheScreen() async throws {
    let model = await makeModel()
    model.select(apiNew.id)
    let api = try #require(model.groups.first)
    model.setExpanded(false, group: api)

    #expect(model.displayedSessions.map(\.name) == ["Web new", "Web old"])
    #expect(model.selectedSessionID == apiNew.id)
    model.selectNext()
    #expect(model.selectedSessionID == webNew.id)
    model.selectPrevious()
    #expect(model.selectedSessionID == webNew.id)
    model.select(position: 2)
    #expect(model.selectedSessionID == webOld.id)
  }

  @Test("Folding the group of the selection keeps it; selecting in a folded group unfolds it")
  func foldingAndSelection() async throws {
    let model = await makeModel()
    model.select(apiOld.id)

    model.collapseSelectedGroup()
    #expect(model.selectedSessionID == apiOld.id)
    #expect(!model.isExpanded(try #require(model.groups.first)))

    model.select(webNew.id)
    model.select(apiNew.id)
    #expect(model.isExpanded(try #require(model.groups.first)))
  }

  @Test("Switching between the views keeps the selection")
  func toggleKeepsTheSelection() async {
    let model = await makeModel()
    model.select(webOld.id)

    model.toggleGrouping()
    #expect(model.sidebarMode == .flat)
    model.toggleGrouping()

    #expect(model.selectedSessionID == webOld.id)
  }

  @Test("A search unfolds every group without changing what is stored")
  func searchUnfolds() async throws {
    let model = await makeModel()
    model.setAllGroupsExpanded(false)
    #expect(model.displayedSessions.isEmpty)

    model.setSearchText("old")

    #expect(model.displayedSessions.map(\.name) == ["Api old", "Web old"])
    #expect(model.layout.collapsedFolders.count == 2)
    model.setSearchText("")
    #expect(model.displayedSessions.isEmpty)
  }

  @Test("Folds, mode and selection come back at launch, a selection in a folded group included")
  func restoredAtLaunch() async throws {
    let store = RecordingLayoutStore()
    let first = await makeModel(store: store)
    first.setSidebarMode(.byFolder)
    first.select(apiOld.id)
    first.collapseSelectedGroup()
    await first.layout.flush()

    let second = await makeModel(store: store)

    #expect(second.sidebarMode == .byFolder)
    #expect(second.selectedSessionID == apiOld.id)
    #expect(!second.isExpanded(try #require(second.groups.first)))
  }

  @Test("Renaming a group changes its title, and nothing about its sessions")
  func renaming() async throws {
    let model = await makeModel()
    let api = try #require(model.groups.first)

    await model.rename(api, to: "Backend")

    let renamed = try #require(model.groups.first)
    #expect(renamed.title == "Backend")
    #expect(renamed.sessions == api.sessions)
    #expect(model.sessions.allSatisfy { $0.repositories.first?.path.hasPrefix("/work/") == true })

    await model.rename(renamed, to: " ")
    #expect(model.groups.first?.title == "api")
  }
}
