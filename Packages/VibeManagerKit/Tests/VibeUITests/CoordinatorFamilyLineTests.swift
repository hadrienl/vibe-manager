import Foundation
import Testing
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The line that ties a coordinator to its children in the sidebar (#387)")
struct CoordinatorFamilyLineTests {
  let parent = WorkSession(
    name: "Coordinator", createdAt: Date(timeIntervalSince1970: 0), taskStatus: .doing, rank: 1,
    coordination: .coordinator)
  let above = WorkSession(
    name: "Above", createdAt: Date(timeIntervalSince1970: 0), taskStatus: .doing, rank: 0)
  let below = WorkSession(
    name: "Below", createdAt: Date(timeIntervalSince1970: 0), taskStatus: .doing, rank: 2)

  private func child(_ name: String, of coordinator: WorkSession) -> WorkSession {
    WorkSession(
      name: name, createdAt: Date(timeIntervalSince1970: 0), taskStatus: .doing, rank: 0,
      coordination: .child(of: coordinator.id))
  }

  private func lines(_ sessions: [WorkSession], done: CoordinatorDoneChildren? = nil)
    -> [String: FamilyLine]
  {
    let items = SidebarItem.items(of: sessions) { $0 == parent.id ? done : nil }
    return SidebarItem.familyLines(of: items)
  }

  private func key(_ session: WorkSession) -> String { session.id.rawValue.uuidString }

  @Test("The coordinator starts the line, the middle child carries it on, the last one ends it")
  func family() {
    let first = child("First", of: parent)
    let middle = child("Middle", of: parent)
    let last = child("Last", of: parent)
    let lines = lines([above, parent, first, middle, last, below])
    #expect(lines[key(above)] == nil)
    #expect(lines[key(parent)] == .parent)
    #expect(lines[key(first)] == .child(isLast: false))
    #expect(lines[key(middle)] == .child(isLast: false))
    #expect(lines[key(last)] == .child(isLast: true))
    #expect(lines[key(below)] == nil)
  }

  @Test("A folded coordinator, or one without children, draws no line")
  func folded() {
    #expect(lines([above, parent, below]).isEmpty)
  }

  @Test("The row of done children ends the line under the last child")
  func doneChildren() {
    let first = child("First", of: parent)
    let lines = lines([parent, first, below], done: .init(count: 2, isShown: false))
    #expect(lines[key(first)] == .child(isLast: false))
    #expect(lines["done-" + key(parent)] == .child(isLast: true))
    #expect(lines[key(below)] == nil)
  }

  @Test("A child listed away from its coordinator is tied to nothing")
  func orphan() {
    let first = child("First", of: parent)
    #expect(lines([above, first, below]).isEmpty)
  }

  @Test("The line runs under the coordinator's badge and stops short of each child's")
  func geometry() {
    let x = SessionRow.disclosureMargin + SessionRow.badgeSize / 2
    let height: CGFloat = 60
    let parentSegments = FamilyLineGeometry.segments(of: .parent, height: height)
    #expect(parentSegments.count == 1)
    #expect(parentSegments[0].from == CGPoint(x: x, y: 30 + 18 + FamilyLineGeometry.gap))
    // Down across the gap between rows, to the first child's piece.
    #expect(parentSegments[0].to == CGPoint(x: x, y: height + FamilyLineGeometry.rowGap))

    let elbowEnd = SessionRow.disclosureMargin + SessionRow.childIndent - FamilyLineGeometry.gap
    let middle = FamilyLineGeometry.segments(of: .child(isLast: false), height: height)
    #expect(
      middle == [
        .init(
          from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: height + FamilyLineGeometry.rowGap)),
        .init(from: CGPoint(x: x, y: 30), to: CGPoint(x: elbowEnd, y: 30)),
      ])
    let last = FamilyLineGeometry.segments(of: .child(isLast: true), height: height)
    #expect(last[0].to == CGPoint(x: x, y: 30))
    #expect(last[1] == middle[1])
    // The elbow reaches toward the child's badge, which sits right of the line.
    #expect(elbowEnd > x)
  }
}
