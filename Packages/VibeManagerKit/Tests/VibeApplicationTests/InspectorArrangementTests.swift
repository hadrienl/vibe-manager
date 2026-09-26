import Foundation
import Testing

@testable import VibeApplication

@Suite("The sections of the context column")
struct InspectorArrangementTests {
  private let six: [InspectorSectionID] = [.activity, .git, .notes, .agent, .usage, .prompt]

  @Test("By default: activity, Git and notes unfolded, the rest folded under them")
  func defaults() {
    let arrangement = InspectorArrangement.default

    #expect(arrangement.order(of: six) == six)
    #expect(!arrangement.isCollapsed(.activity))
    #expect(!arrangement.isCollapsed(.git))
    #expect(!arrangement.isCollapsed(.notes))
    #expect(arrangement.isCollapsed(.agent))
    #expect(arrangement.isCollapsed(.usage))
    #expect(arrangement.isCollapsed(.prompt))
  }

  @Test("Move Up and Move Down stop at the ends")
  func moveByOne() {
    var arrangement = InspectorArrangement.default

    arrangement.move(.notes, by: -1, among: six)
    #expect(arrangement.order(of: six) == [.activity, .notes, .git, .agent, .usage, .prompt])
    arrangement.move(.activity, by: -1, among: six)
    #expect(arrangement.order(of: six).first == .activity)
    arrangement.move(.prompt, by: 1, among: six)
    #expect(arrangement.order(of: six).last == .prompt)
    arrangement.move(.activity, by: 1, among: six)
    #expect(arrangement.order(of: six) == [.notes, .activity, .git, .agent, .usage, .prompt])

    #expect(!arrangement.canMove(.notes, by: -1, among: six))
    #expect(arrangement.canMove(.notes, by: 1, among: six))
    #expect(!arrangement.canMove(.prompt, by: 1, among: six))
  }

  @Test("A section that is not shown is never a step of Move Up or Move Down")
  func movingSkipsHiddenSections() {
    let future = InspectorSectionID("future")
    var arrangement = InspectorArrangement(entries: [
      .init(id: .git, isCollapsed: false),
      .init(id: future, isCollapsed: false),
      .init(id: .notes, isCollapsed: false),
    ])

    arrangement.move(.notes, by: -1, among: [.git, .notes])

    #expect(arrangement.order(of: [.git, .notes]) == [.notes, .git])
    // Still there, for the build that knows it.
    #expect(arrangement.entry(future) != nil)
  }

  @Test("A header dropped before another, after another, or last")
  func moveToTarget() {
    var arrangement = InspectorArrangement.default

    arrangement.move(.prompt, before: .activity)
    #expect(arrangement.order(of: six) == [.prompt, .activity, .git, .notes, .agent, .usage])
    arrangement.move(.prompt, after: .notes)
    #expect(arrangement.order(of: six) == [.activity, .git, .notes, .prompt, .agent, .usage])
    arrangement.move(.activity, before: nil)
    #expect(arrangement.order(of: six) == [.git, .notes, .prompt, .agent, .usage, .activity])
    arrangement.move(.git, before: .git)
    #expect(arrangement.order(of: six).first == .git)
  }

  @Test("Folding one, all, or all the others")
  func folding() {
    var arrangement = InspectorArrangement.default

    arrangement.setCollapsed(.git, true)
    #expect(arrangement.isCollapsed(.git))

    arrangement.setCollapsed(true, among: six)
    #expect(six.allSatisfy(arrangement.isCollapsed))
    arrangement.setCollapsed(false, among: six)
    #expect(!six.contains(where: arrangement.isCollapsed))

    arrangement.collapseOthers(than: .notes, among: six)
    #expect(six.filter { !arrangement.isCollapsed($0) } == [.notes])
  }

  @Test("Resizing rewrites the weights it is given, and only those")
  func resizing() {
    var arrangement = InspectorArrangement.default

    arrangement.resize(to: [.git: 300, .notes: 100, .agent: .nan, .usage: -4])

    #expect(arrangement.weight(.git) == 300)
    #expect(arrangement.weight(.notes) == 100)
    #expect(arrangement.weight(.activity) == 1)
    #expect(arrangement.weight(.agent) == 1)
    #expect(arrangement.weight(.usage) == 1)
  }

  @Test("A section new in this build goes after the one declared before it")
  func newSectionsAreInserted() {
    let stored = InspectorArrangement(entries: [
      .init(id: .notes, isCollapsed: false),
      .init(id: .git, isCollapsed: true),
    ])

    let resolved = stored.resolved(declared: six)

    #expect(resolved.entries.map(\.id) == [.activity, .notes, .agent, .usage, .prompt, .git])
    #expect(resolved.isCollapsed(.git))
    #expect(resolved.isCollapsed(.agent))
  }

  @Test("A section this build does not know is kept, in its place, and written back as it was")
  func unknownSectionsSurvive() throws {
    let json = Data(
      #"""
      {"entries": [
        {"id": "git", "isCollapsed": false, "weight": 2},
        {"id": "llm-costs", "isCollapsed": true, "weight": 3},
        {"id": "notes", "isCollapsed": false, "weight": 1},
        {"id": 42},
        {"id": "git", "isCollapsed": true, "weight": 9},
        {"id": "agent", "isCollapsed": false, "weight": -1}
      ]}
      """#.utf8)

    let arrangement = try JSONDecoder().decode(InspectorArrangement.self, from: json)

    #expect(arrangement.entries.map(\.id.rawValue) == ["git", "llm-costs", "notes", "agent"])
    #expect(arrangement.weight(.git) == 2)
    #expect(arrangement.weight(.agent) == 1)
    #expect(arrangement.order(of: six) == [.activity, .git, .notes, .agent, .usage, .prompt])

    let again = try JSONDecoder().decode(
      InspectorArrangement.self, from: JSONEncoder().encode(arrangement))
    #expect(again == arrangement)
  }
}

@Suite("Sharing the column's height between its sections")
struct InspectorHeightsTests {
  private typealias Demand = InspectorHeights.Demand

  @Test("In proportion to the weights")
  func proportional() {
    let heights = InspectorHeights.distribute(
      400,
      among: [
        Demand(id: .git, weight: 3, minimum: 50), Demand(id: .notes, weight: 1, minimum: 50),
      ])

    #expect(heights == [.git: 300, .notes: 100])
  }

  @Test("Never under a minimum: the others give way")
  func minimums() {
    let heights = InspectorHeights.distribute(
      400,
      among: [
        Demand(id: .git, weight: 9, minimum: 50), Demand(id: .notes, weight: 1, minimum: 120),
      ])

    #expect(heights == [.git: 280, .notes: 120])
  }

  @Test("When the minimums do not fit, each gets its own and the column scrolls")
  func overflow() {
    let heights = InspectorHeights.distribute(
      100,
      among: [
        Demand(id: .git, weight: 1, minimum: 120), Demand(id: .notes, weight: 1, minimum: 90),
        Demand(id: .activity, weight: 1, minimum: 90),
      ])

    #expect(heights == [.git: 120, .notes: 90, .activity: 90])
  }

  @Test("A section never takes more than its content; the rest goes to the others")
  func fitting() {
    let heights = InspectorHeights.distribute(
      600,
      among: [
        Demand(id: .git, weight: 1, minimum: 120),
        Demand(id: .usage, weight: 1, minimum: 60, maximum: 80),
        Demand(id: .notes, weight: 1, minimum: 90),
      ])

    #expect(heights == [.git: 260, .usage: 80, .notes: 260])
  }

  @Test("Sections that all fit their content leave the rest empty")
  func allFitting() {
    let heights = InspectorHeights.distribute(
      600,
      among: [
        Demand(id: .agent, weight: 1, minimum: 60, maximum: 100),
        Demand(id: .usage, weight: 1, minimum: 60, maximum: 80),
      ])

    #expect(heights == [.agent: 100, .usage: 80])
  }

  @Test("A section alone takes everything; none unfolded takes nothing")
  func aloneOrNone() {
    #expect(
      InspectorHeights.distribute(500, among: [Demand(id: .notes, weight: 0.2, minimum: 90)])
        == [.notes: 500])
    #expect(InspectorHeights.distribute(500, among: []).isEmpty)
  }

  @Test("Weights and room that are not numbers still lay out")
  func invalidNumbers() {
    let heights = InspectorHeights.distribute(
      .nan,
      among: [
        Demand(id: .git, weight: .nan, minimum: 50), Demand(id: .notes, weight: 0, minimum: -3),
      ])

    #expect(heights == [.git: 50, .notes: 0])
    #expect(
      InspectorHeights.distribute(
        200,
        among: [
          Demand(id: .git, weight: .infinity, minimum: 0),
          Demand(id: .notes, weight: 1, minimum: 0),
        ])
        == [.git: 100, .notes: 100])
  }
}
