import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("The order the user arranges the sessions in by hand")
struct SessionOrderTests {
  private func session(_ name: String, rank: Int, folder: String? = nil) -> WorkSession {
    WorkSession(
      name: name,
      repositories: folder.map { [RepositoryContext(path: $0)] } ?? [],
      taskStatus: .todo, rank: rank)
  }

  /// Applies the ranks a move hands out, as the store would.
  private func applying(_ ranks: [SessionID: Int], to sessions: [WorkSession]) -> [WorkSession] {
    sessions.map { session in
      var moved = session
      moved.rank = ranks[session.id] ?? session.rank
      return moved
    }
  }

  private func grouped(_ sessions: [WorkSession]) -> [SessionGroup] {
    SessionGrouping.groups(
      of: SessionFilter(column: .todo, sort: .manual).apply(to: sessions),
      key: { SessionFolderKey.primaryPath(of: $0).map(SessionFolderKey.lexical) })
  }

  @Test("Rank first, then the identifier when two ranks are equal")
  func ordered() {
    let a = session("A", rank: 2)
    let b = session("B", rank: 0)
    let c = session("C", rank: 2)
    let tied = [a, c].sorted { $0.id.description < $1.id.description }.map(\.name)

    #expect(SessionOrder.ordered([a, b, c]).map(\.name) == ["B"] + tied)
  }

  @Test("A session goes to the top, the bottom or between two others")
  func moving() throws {
    let list = [session("A", rank: 0), session("B", rank: 1), session("C", rank: 2)]
    let c = list[2].id

    #expect(try #require(SessionOrder.moving(c, to: 0, in: list)).map(\.name) == ["C", "A", "B"])
    #expect(
      try #require(SessionOrder.moving(list[0].id, to: 2, in: list)).map(\.name)
        == ["B", "C", "A"])
    #expect(try #require(SessionOrder.moving(c, to: 1, in: list)).map(\.name) == ["A", "C", "B"])
    #expect(SessionOrder.moving(c, to: 2, in: list) == nil)
    #expect(SessionOrder.moving(SessionID(), to: 0, in: list) == nil)
  }

  @Test("A move hands the subset its own ranks back, and touches nothing else")
  func redistributionStaysInTheSubset() throws {
    // Another column's sessions sit between these ranks.
    let column = [session("A", rank: 0), session("B", rank: 3), session("C", rank: 7)]
    let reordered = try #require(SessionOrder.moving(column[2].id, to: 0, in: column))

    let ranks = SessionOrder.redistribute(reordered, among: column)

    #expect(Set(ranks.values).isSubset(of: [0, 3, 7]))
    #expect(ranks == [column[2].id: 0, column[0].id: 3, column[1].id: 7])
  }

  @Test("Equal ranks are spread apart, so the order asked for is the order stored")
  func tiesAreSpread() {
    let a = session("A", rank: 4)
    let b = session("B", rank: 4)
    let ranks = SessionOrder.redistribute([b, a], among: [a, b])
    let stored = applying(ranks, to: [a, b])

    #expect(SessionOrder.ordered(stored).map(\.name) == ["B", "A"])
  }

  @Test("A tie is never pushed onto a session outside the subset")
  func tiesStayOutOfOtherSessions() throws {
    let sessions = [
      session("Api 1", rank: 5, folder: "/work/api"),
      session("Api 2", rank: 5, folder: "/work/api"),
      session("Web 1", rank: 6, folder: "/work/web"),
    ]
    let api = try #require(grouped(sessions).first)
    let reordered = try #require(SessionOrder.moving(api.sessions[1].id, to: 0, in: api.sessions))
    let after = applying(SessionOrder.redistribute(reordered, among: sessions), to: sessions)

    #expect(Set(after.map(\.rank)).count == after.count)
    #expect(SessionOrder.ordered(after).map(\.name) == reordered.map(\.name) + ["Web 1"])
  }

  @Test("Moving a session inside its group never moves the group")
  func groupOrderIsKept() throws {
    let sessions = [
      session("Api 1", rank: 0, folder: "/work/api"),
      session("Web 1", rank: 1, folder: "/work/web"),
      session("Api 2", rank: 2, folder: "/work/api"),
    ]
    let api = try #require(grouped(sessions).first)
    // The first session of the group goes under the second one: inserted into the global order,
    // Api 1 would land after Web 1, and the group of Web would take the top.
    let reordered = try #require(SessionOrder.moving(api.sessions[0].id, to: 1, in: api.sessions))
    let after = applying(SessionOrder.redistribute(reordered, among: sessions), to: sessions)

    #expect(grouped(after).map(\.folderName) == ["api", "web"])
    #expect(grouped(after).first?.sessions.map(\.name) == ["Api 2", "Api 1"])
  }

  @Test("The flat list and the grouped one tell the same order, whichever was rearranged")
  func sharedBetweenModes() throws {
    let sessions = [
      session("Api 1", rank: 0, folder: "/work/api"),
      session("Web 1", rank: 1, folder: "/work/web"),
      session("Api 2", rank: 2, folder: "/work/api"),
      session("Web 2", rank: 3, folder: "/work/web"),
    ]
    let flat = SessionFilter(column: .todo, sort: .manual)

    // Rearranged in the grouped view: Web 2 above Web 1.
    let web = try #require(grouped(sessions).last)
    let inGroup = try #require(SessionOrder.moving(web.sessions[1].id, to: 0, in: web.sessions))
    let afterGroupMove = applying(SessionOrder.redistribute(inGroup, among: sessions), to: sessions)
    #expect(
      flat.apply(to: afterGroupMove).map(\.name) == ["Api 1", "Web 2", "Api 2", "Web 1"])

    // Rearranged in the flat list: Api 2 to the top.
    let list = flat.apply(to: afterGroupMove)
    let inList = try #require(SessionOrder.moving(list[2].id, to: 0, in: list))
    let afterListMove = applying(
      SessionOrder.redistribute(inList, among: afterGroupMove), to: afterGroupMove)
    #expect(grouped(afterListMove).first?.sessions.map(\.name) == ["Api 2", "Api 1"])
  }

  @Test("A group moved brings its sessions together there; No Folder stays last")
  func movingAGroup() throws {
    let sessions = [
      session("Api 1", rank: 0, folder: "/work/api"),
      session("Web 1", rank: 1, folder: "/work/web"),
      session("Loose", rank: 2),
      session("Api 2", rank: 3, folder: "/work/api"),
      session("Cli 1", rank: 4, folder: "/work/cli"),
    ]
    let groups = grouped(sessions)
    let cli = SessionFolderKey.lexical("/work/cli")

    let reordered = try #require(SessionOrder.movingGroup(cli, to: 0, in: groups))
    #expect(reordered.map(\.name) == ["Cli 1", "Api 1", "Api 2", "Web 1", "Loose"])

    let after = applying(SessionOrder.redistribute(reordered, among: sessions), to: sessions)
    #expect(grouped(after).map(\.folderName) == ["cli", "api", "web", ""])
    #expect(SessionOrder.movingGroup(cli, to: 0, in: grouped(after)) == nil)
  }
}

@Suite("Writing the order arranged by hand")
struct ReorderSessionsTests {
  @Test("Only the ranks change, and a move that changes nothing writes nothing")
  func writesRanksOnly() async throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let a = WorkSession(name: "A", updatedAt: date, rank: 0)
    let b = WorkSession(name: "B", updatedAt: date, rank: 1)
    let repository = RecordingRepository([a, b])
    let reorder = ReorderSessions(repository: repository)

    #expect(try await reorder([a, b]) == 0)
    #expect(await repository.reorders.isEmpty)

    #expect(try await reorder([b, a]) == 2)
    let stored = await repository.sessions()
    #expect(SessionOrder.ordered(stored).map(\.name) == ["B", "A"])
    #expect(stored.allSatisfy { $0.updatedAt == date })
    #expect(await repository.reorders.count == 1)
  }
}

private actor RecordingRepository: SessionRepository {
  private var stored: [WorkSession]
  private(set) var reorders: [[SessionID: Int]] = []

  init(_ sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? { stored.first { $0.id == id } }

  func save(_ session: WorkSession) {
    stored.removeAll { $0.id == session.id }
    stored.append(session)
  }

  func reorder(_ ranks: [SessionID: Int]) {
    reorders.append(ranks)
    for index in stored.indices {
      if let rank = ranks[stored[index].id] { stored[index].rank = rank }
    }
  }
}
