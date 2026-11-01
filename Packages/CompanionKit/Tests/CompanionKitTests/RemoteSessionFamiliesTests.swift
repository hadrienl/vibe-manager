import CompanionCore
import Foundation
import Testing

private func session(
  _ id: String, _ status: RemoteTaskStatus = .doing, under coordinator: String? = nil,
  folder: String = "/a", rank: Int = 0
) -> RemoteSession {
  RemoteSession(
    id: id, name: id, folderPath: folder, folderName: folder, agentName: "Claude", status: status,
    activity: .idle, appearance: RemoteAppearance(symbol: "star", color: "#000000", iconID: nil),
    coordinatorID: coordinator, isCoordinator: coordinator == nil,
    updatedAt: Date(timeIntervalSince1970: 0), rank: rank, hasStarted: true)
}

private func ids(_ groups: [RemoteSessionGroup]) -> [String] {
  groups.flatMap(\.rows).map(\.id)
}

@Test("A child is listed under its coordinator, in its column, with its own status said")
func childInCoordinatorColumn() throws {
  let families = RemoteSessionFamilies([
    session("c"), session("k", .waiting, under: "c", folder: "/other"),
  ])
  let rows = try #require(families.groups(in: .doing, showingDone: []).first).rows
  #expect(rows.map(\.id) == ["c", "k"])
  #expect(rows[0].line == .parent)
  #expect(rows[1].line == .child(isLast: true))
  #expect(rows[1].isChild)
  guard case .session(_, let ownStatus) = rows[1].content else {
    Issue.record("Not a session")
    return
  }
  #expect(ownStatus == .waiting)
  #expect(families.groups(in: .waiting, showingDone: []).isEmpty)
  #expect(families.count(in: .doing) == 2)
  #expect(families.count(in: .waiting) == 0)
}

@Test("Only the last row of a family ends the line; a session alone draws none")
func lines() {
  let families = RemoteSessionFamilies([
    session("c", rank: 0), session("k1", under: "c", rank: 0), session("k2", under: "c", rank: 1),
    session("plain", rank: 1),
  ])
  let rows = families.groups(in: .doing, showingDone: []).flatMap(\.rows)
  #expect(rows.map(\.id) == ["c", "k1", "k2", "plain"])
  #expect(
    rows.map(\.line) == [.parent, .child(isLast: false), .child(isLast: true), nil])
}

@Test("Done children wait behind a row, which ends the line, until they are asked for")
func doneChildren() {
  let families = RemoteSessionFamilies([
    session("c"), session("k", under: "c"), session("d", .done, under: "c"),
  ])
  let folded = families.groups(in: .doing, showingDone: []).flatMap(\.rows)
  #expect(folded.map(\.id) == ["c", "k", "done-c"])
  #expect(folded[2].content == .doneChildren(coordinatorID: "c", count: 1, isShown: false))
  #expect(folded[2].line == .child(isLast: true))
  let shown = families.groups(in: .doing, showingDone: ["c"]).flatMap(\.rows)
  #expect(Set(shown.map(\.id)) == ["c", "k", "d", "done-c"])
  #expect(shown.last?.content == .doneChildren(coordinatorID: "c", count: 1, isShown: true))
}

@Test("A coordinator whose children are all done still draws its line to their row")
func onlyDoneChildren() {
  let families = RemoteSessionFamilies([session("c"), session("d", .done, under: "c")])
  let rows = families.groups(in: .doing, showingDone: []).flatMap(\.rows)
  #expect(rows.map(\.id) == ["c", "done-c"])
  #expect(rows[0].line == .parent)
}

@Test("A child of an archived, gone or itself listed coordinator stands alone in its own column")
func orphans() {
  let families = RemoteSessionFamilies([
    session("archived", .archived), session("a", .waiting, under: "archived"),
    session("b", .waiting, under: "gone"),
    session("top"), session("middle", under: "top"), session("c", .waiting, under: "middle"),
  ])
  let waiting = ids(families.groups(in: .waiting, showingDone: []))
  #expect(Set(waiting) == ["a", "b", "c"])
  let rows = families.groups(in: .waiting, showingDone: []).flatMap(\.rows)
  #expect(rows.allSatisfy { $0.line == nil })
}

@Test("An archived child is listed nowhere in its coordinator's family")
func archivedChild() {
  let families = RemoteSessionFamilies([session("c"), session("k", .archived, under: "c")])
  #expect(ids(families.groups(in: .doing, showingDone: [])) == ["c"])
  #expect(families.count(in: .doing) == 1)
}
