import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Workspace layout")
struct WorkspaceLayoutTests {
  @Test("A width outside its range is bounded rather than refused")
  func widthsAreBounded() {
    #expect(
      WorkspaceLayout(sidebarWidth: 10_000).sidebarWidth
        == WorkspaceLayout.sidebarWidthRange.upperBound)
    #expect(
      WorkspaceLayout(sidebarWidth: 1).sidebarWidth == WorkspaceLayout.sidebarWidthRange.lowerBound)
  }

  @Test("A width that is not a number falls back to the default")
  func unmeasuredWidthFallsBack() {
    #expect(WorkspaceLayout(sidebarWidth: .nan).sidebarWidth == 280)
    #expect(WorkspaceLayout(sidebarWidth: .infinity).sidebarWidth == 280)
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

  @Test(
    "Centring the web view gives both panes the same width, as far as the bounds allow",
    arguments: [
      // Room for both halves.
      (1_409.0, 700.0),
      // The middle would narrow the terminal under its minimum: the web view gives way.
      (1_100.0, 531.0),
      // The middle is wider than the web view may be.
      (3_000.0, 1_200.0),
      // Too narrow for both: the web view keeps its own minimum.
      (800.0, 380.0),
      (.nan, 380.0),
      (0.0, 380.0),
    ])
  func centredBrowserWidth(container: Double, expected: Double) {
    let width = WorkspaceLayout.centeredBrowserWidth(
      in: container, handle: 9, terminalMinimum: 560)

    #expect(width == expected)
  }

  @Test("A stored layout survives a round trip")
  func roundTrip() throws {
    let layout = WorkspaceLayout(
      selectedSessionID: SessionID(),
      isSidebarVisible: false,
      sidebarWidth: 300,
      notesPlacement: .panel
    )

    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: data) == layout)
  }

  @Test("A width decoded from a foreign document is bounded like a measured one")
  func decodingBounds() throws {
    let json = Data(#"{"sidebarWidth": 9000}"#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)

    #expect(layout.sidebarWidth == WorkspaceLayout.sidebarWidthRange.upperBound)
    #expect(layout.isSidebarVisible)
    #expect(layout.notesPlacement == .popover)
  }

  @Test("A layout written with the right column reads without it, and never writes it again (#578)")
  func rightColumnIsReadPast() throws {
    let json = Data(
      #"{"sidebarWidth": 300, "isInspectorVisible": false, "inspectorWidth": 340}"#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)
    let written = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])

    #expect(layout.sidebarWidth == 300)
    #expect(written["isInspectorVisible"] == nil)
    #expect(written["inspectorWidth"] == nil)
  }

  @Test("A notes placement written by a later build costs the placement only")
  func unknownNotesPlacement() throws {
    let json = Data(#"{"sidebarWidth": 300, "notesPlacement": "sheet"}"#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)

    #expect(layout.notesPlacement == .popover)
    #expect(layout.sidebarWidth == 300)
  }

  @Test("The sections of the right column, and the keys from before #66, are read past (#578)")
  func sectionsAreReadPast() throws {
    let json = Data(
      #"""
      {"sidebarWidth": 300, "inspectorSplit": 0.7, "isSessionDetailsExpanded": false,
       "inspectorTopTab": "git", "inspectorSections": {"entries": "nonsense"}}
      """#.utf8)

    let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: json)
    let written = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])

    #expect(layout.sidebarWidth == 300)
    for key in [
      "inspectorSplit", "isSessionDetailsExpanded", "inspectorTopTab", "inspectorSections",
    ] {
      #expect(written[key] == nil)
    }
  }
}

@Suite("Which columns fit")
struct WorkspaceLayoutPolicyTests {
  private let open = WorkspaceLayout(isSidebarVisible: true)

  @Test("A wide window shows what the user asked for")
  func wideWindowFollowsIntent() {
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: open).isSidebarVisible)
  }

  @Test("The sidebar keeps its place down to 820 points, the right column gone (#578)")
  func sidebarFolds() {
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 900, intent: open).isSidebarVisible)
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 820, intent: open).isSidebarVisible)
    #expect(!WorkspaceLayoutPolicy.resolve(windowWidth: 700, intent: open).isSidebarVisible)
  }

  @Test("Folding the sidebar never decides for the user: widening brings it back")
  func intentSurvivesFolding() {
    var intent = open
    #expect(!WorkspaceLayoutPolicy.resolve(windowWidth: 700, intent: intent).isSidebarVisible)
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: intent).isSidebarVisible)

    // A sidebar the user closed stays closed at any width.
    intent.isSidebarVisible = false
    #expect(!WorkspaceLayoutPolicy.resolve(windowWidth: 1_400, intent: intent).isSidebarVisible)
  }

  @Test("An unmeasured window shows the stored columns rather than folding them away")
  func unmeasuredWindowFollowsIntent() {
    #expect(WorkspaceLayoutPolicy.resolve(windowWidth: 0, intent: open).isSidebarVisible)
  }
}
