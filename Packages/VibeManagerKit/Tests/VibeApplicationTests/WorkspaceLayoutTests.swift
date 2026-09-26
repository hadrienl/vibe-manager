import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Workspace layout")
struct WorkspaceLayoutTests {
  @Test("A width outside its range is bounded rather than refused")
  func widthsAreBounded() {
    let layout = WorkspaceLayout(sidebarWidth: 10_000, inspectorWidth: 1)

    #expect(layout.sidebarWidth == WorkspaceLayout.sidebarWidthRange.upperBound)
    #expect(layout.inspectorWidth == WorkspaceLayout.inspectorWidthRange.lowerBound)
  }

  @Test("A width that is not a number falls back to the default")
  func unmeasuredWidthFallsBack() {
    let layout = WorkspaceLayout(sidebarWidth: .nan, inspectorWidth: .infinity)

    #expect(layout.sidebarWidth == 280)
    #expect(WorkspaceLayout.inspectorWidthRange.contains(layout.inspectorWidth))
  }

  @Test("A width a folding column reports is not an arrangement")
  func foldingWidthsAreNotMeasurements() {
    #expect(WorkspaceLayout.measured(0, in: WorkspaceLayout.sidebarWidthRange) == nil)
    #expect(WorkspaceLayout.measured(120, in: WorkspaceLayout.sidebarWidthRange) == nil)
    #expect(WorkspaceLayout.measured(.nan, in: WorkspaceLayout.sidebarWidthRange) == nil)
    #expect(WorkspaceLayout.measured(300, in: WorkspaceLayout.sidebarWidthRange) == 300)
    #expect(
      WorkspaceLayout.measured(10_000, in: WorkspaceLayout.sidebarWidthRange)
        == WorkspaceLayout.sidebarWidthRange.upperBound
    )
  }

  @Test("A stored layout survives a round trip")
  func roundTrip() throws {
    let layout = WorkspaceLayout(
      selectedSessionID: SessionID(),
      isSidebarVisible: false,
      isInspectorVisible: false,
      sidebarWidth: 300,
      inspectorWidth: 320,
      inspectorSections: InspectorArrangement(entries: [
        .init(id: .notes, isCollapsed: false, weight: 2), .init(id: .git, isCollapsed: true),
      ])
    )

    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: data) == layout)
  }

  @Test("A width decoded from a foreign document is bounded like a measured one")
  func decodingBounds() throws {
    let json = Data(#"{"sidebarWidth": 9000, "inspectorWidth": -3}"#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)

    #expect(layout.sidebarWidth == WorkspaceLayout.sidebarWidthRange.upperBound)
    #expect(layout.inspectorWidth == WorkspaceLayout.inspectorWidthRange.lowerBound)
    #expect(layout.isSidebarVisible)
    #expect(layout.isInspectorVisible)
  }

  @Test("A layout stored before #66 arranges the sections as the column was")
  func migratesTheColumn() throws {
    let json = Data(
      #"""
      {"sidebarWidth": 300, "inspectorWidth": 320, "inspectorSplit": 0.7,
       "isSessionDetailsExpanded": false, "inspectorTopTab": "git"}
      """#.utf8)

    let sections = try JSONDecoder().decode(WorkspaceLayout.self, from: json).inspectorSections

    let six: [InspectorSectionID] = [.activity, .git, .notes, .agent, .usage, .prompt]
    #expect(sections.order(of: six) == [.git, .activity, .notes, .agent, .usage, .prompt])
    #expect(!sections.isCollapsed(.git))
    #expect(sections.isCollapsed(.activity))
    #expect(!sections.isCollapsed(.notes))
    #expect(sections.isCollapsed(.agent) && sections.isCollapsed(.usage))
    #expect(sections.isCollapsed(.prompt))
    #expect(abs(sections.weight(.git) - 0.7) < 0.0001)
    #expect(abs(sections.weight(.notes) - 0.3) < 0.0001)
  }

  @Test("The activity on top, the details unfolded, and a split out of bounds")
  func migratesActivityOnTop() throws {
    let json = Data(
      #"{"inspectorSplit": 0.99, "isSessionDetailsExpanded": true, "inspectorTopTab": "activity"}"#
        .utf8)

    let sections = try JSONDecoder().decode(WorkspaceLayout.self, from: json).inspectorSections

    #expect(sections.entries.map(\.id).prefix(3) == [.activity, .git, .notes])
    #expect(!sections.isCollapsed(.activity) && sections.isCollapsed(.git))
    #expect(!sections.isCollapsed(.agent) && !sections.isCollapsed(.prompt))
    #expect(abs(sections.weight(.activity) - 0.85) < 0.0001)
  }

  @Test("A layout that never arranged the column gets the default sections")
  func noColumnYet() throws {
    let json = Data(#"{"sidebarWidth": 300, "inspectorWidth": 320}"#.utf8)

    #expect(
      try JSONDecoder().decode(WorkspaceLayout.self, from: json).inspectorSections == .default)
  }

  @Test("Unreadable sections cost the sections, not the rest of the layout")
  func unreadableSections() throws {
    let json = Data(#"{"sidebarWidth": 300, "inspectorSections": "nonsense"}"#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)

    #expect(layout.inspectorSections == .default)
    #expect(layout.sidebarWidth == 300)
  }

  @Test("The keys of the old column are never written again")
  func legacyKeysAreDropped() throws {
    let json = Data(#"{"inspectorSplit": 0.4, "inspectorTopTab": "git"}"#.utf8)
    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)

    let written = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])

    #expect(written["inspectorSplit"] == nil)
    #expect(written["inspectorTopTab"] == nil)
    #expect(written["isSessionDetailsExpanded"] == nil)
    #expect(written["inspectorSections"] != nil)
    // Once written in the new form, the old keys no longer say anything.
    let again = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
    #expect(again.inspectorSections == layout.inspectorSections)
  }
}

@Suite("Which columns fit")
struct WorkspaceLayoutPolicyTests {
  private let open = WorkspaceLayout(isSidebarVisible: true, isInspectorVisible: true)

  @Test("A wide window shows what the user asked for")
  func wideWindowFollowsIntent() {
    let columns = WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: open)

    #expect(columns.isSidebarVisible)
    #expect(columns.isInspectorVisible)
  }

  @Test("The inspector folds first, then the sidebar")
  func columnsFoldInOrder() {
    let medium = WorkspaceLayoutPolicy.resolve(windowWidth: 900, intent: open)
    #expect(medium.isSidebarVisible)
    #expect(!medium.isInspectorVisible)

    let narrow = WorkspaceLayoutPolicy.resolve(windowWidth: 700, intent: open)
    #expect(!narrow.isSidebarVisible)
    #expect(!narrow.isInspectorVisible)
  }

  @Test("Folding a column never decides for the user: widening brings it back")
  func intentSurvivesFolding() {
    var intent = open
    #expect(!WorkspaceLayoutPolicy.resolve(windowWidth: 700, intent: intent).isInspectorVisible)
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: intent).isInspectorVisible)

    // A column the user closed stays closed at any width.
    intent.isInspectorVisible = false
    #expect(!WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: intent).isInspectorVisible)
  }

  @Test("An unmeasured window shows the stored columns rather than folding them away")
  func unmeasuredWindowFollowsIntent() {
    let columns = WorkspaceLayoutPolicy.resolve(windowWidth: 0, intent: open)

    #expect(columns.isSidebarVisible)
    #expect(columns.isInspectorVisible)
  }
}
