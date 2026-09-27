import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Several sessions selected in the sidebar")
struct SessionSelectionTests {
  private let rows = (0..<5).map { _ in SessionID() }

  private func selection(showing index: Int) -> SessionSelection {
    SessionSelection(displayed: rows[index])
  }

  @Test("A plain click selects one session and shows it")
  func plainClick() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[2]], displayOrder: rows)
    selection.applyList([rows[3]], displayOrder: rows)

    #expect(selection.displayed == rows[3])
    #expect(selection.members == [rows[3]])
    #expect(!selection.isMultiple)
  }

  @Test("A ⌘-click that adds a row shows that row, and keeps the others selected")
  func commandClickAdds() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[3]], displayOrder: rows)

    #expect(selection.displayed == rows[3])
    #expect(selection.ids == [rows[0], rows[3]])
    #expect(selection.isMultiple)
  }

  @Test("A ⌘-click that takes out another row leaves the session on screen")
  func commandClickRemovesAnother() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[2]], displayOrder: rows)
    selection.applyList([rows[0], rows[2], rows[4]], displayOrder: rows)
    selection.applyList([rows[0], rows[4]], displayOrder: rows)

    #expect(selection.displayed == rows[4])
    #expect(selection.ids == [rows[0], rows[4]])
  }

  @Test("A ⌘-click that takes out the session on screen shows the nearest row still selected")
  func commandClickRemovesTheDisplayedOne() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[2]], displayOrder: rows)
    selection.applyList([rows[0], rows[2], rows[4]], displayOrder: rows)
    selection.applyList([rows[0], rows[2]], displayOrder: rows)

    #expect(selection.displayed == rows[2])
  }

  @Test("A ⇧-click that shrinks a range shows the row clicked, not the one added last")
  func shiftClickShrinksTheRange() {
    var selection = selection(showing: 4)
    selection.applyList(Set(rows[1...4]), displayOrder: rows)
    #expect(selection.displayed == rows[1])

    selection.applyList(Set(rows[2...4]), displayOrder: rows)
    #expect(selection.displayed == rows[2])
    #expect(selection.members.last == rows[2])

    selection.applyList(Set(rows[3...4]), displayOrder: rows)
    #expect(selection.displayed == rows[3])
  }

  @Test("A ⇧-click range shows the row clicked, its far end, in both directions")
  func shiftClickRange() {
    var down = selection(showing: 1)
    down.applyList(Set(rows[1...3]), displayOrder: rows)
    #expect(down.displayed == rows[3])
    #expect(down.members.last == rows[3])

    var up = selection(showing: 3)
    up.applyList(Set(rows[0...3]), displayOrder: rows)
    #expect(up.displayed == rows[0])
  }

  @Test("⌘A selects every row and leaves the session on screen where it is")
  func selectAll() {
    var selection = selection(showing: 2)
    selection.applyList(Set(rows), displayOrder: rows)

    #expect(selection.displayed == rows[2])
    #expect(selection.ids == Set(rows))
  }

  @Test("Collapsing goes back to one session")
  func collapse() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[1]], displayOrder: rows)
    selection.collapse(to: rows[1])

    #expect(selection.members == [rows[1]])
    #expect(selection.displayed == rows[1])
  }

  @Test("Showing a member keeps the selection; showing another session replaces it")
  func show() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[1]], displayOrder: rows)

    selection.show(rows[0])
    #expect(selection.ids == [rows[0], rows[1]])
    #expect(selection.displayed == rows[0])

    selection.show(rows[4])
    #expect(selection.members == [rows[4]])
  }

  @Test("Rows no longer drawn leave the selection, but not the session on screen")
  func prune() {
    var selection = selection(showing: 0)
    selection.applyList([rows[0], rows[1], rows[2]], displayOrder: rows)
    #expect(selection.displayed == rows[2])

    selection.prune(keeping: [rows[1]])

    #expect(selection.ids == [rows[1], rows[2]])
    #expect(selection.displayed == rows[2])
  }
}

@Suite("The plan of a command on several sessions")
struct SessionBatchPlanTests {
  @Test("Eligible sessions keep their order; the others are set aside with their reason")
  func make() {
    let ids = (0..<4).map { _ in SessionID() }
    let plan = SessionBatchPlan.make(.close, ids: ids + [ids[0]]) { id in
      id == ids[1] ? .alreadyClosed : id == ids[3] ? .busy : nil
    }

    #expect(plan.eligible == [ids[0], ids[2]])
    #expect(plan.skipped == [ids[1]: .alreadyClosed, ids[3]: .busy])
    #expect(!plan.isEmpty)
  }

  @Test("The reasons are counted in a stable order")
  func skippedCounts() {
    let ids = (0..<3).map { _ in SessionID() }
    let plan = SessionBatchPlan.make(.restart, ids: ids) { id in
      id == ids[0] ? .agentUnavailable : .stillRunning
    }

    #expect(plan.isEmpty)
    #expect(plan.skippedCounts.map(\.reason) == [.stillRunning, .agentUnavailable])
    #expect(plan.skippedCounts.map(\.count) == [2, 1])
  }
}
