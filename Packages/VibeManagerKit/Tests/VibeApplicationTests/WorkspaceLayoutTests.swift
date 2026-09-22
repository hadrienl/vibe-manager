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

  @Test("A stored layout survives a round trip")
  func roundTrip() throws {
    let layout = WorkspaceLayout(
      selectedSessionID: SessionID(),
      isSidebarVisible: false,
      isInspectorVisible: false,
      sidebarWidth: 300,
      inspectorWidth: 320
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
