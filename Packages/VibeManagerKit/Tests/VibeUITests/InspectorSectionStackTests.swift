import AppKit
import SwiftUI
import Testing
import VibeApplication

@testable import VibeUI

@MainActor
@Suite("A section added to the context column", .timeLimit(.minutes(1)))
struct InspectorSectionStackTests {
  /// Where a section's content says how tall it was drawn.
  @MainActor
  final class Probe {
    var heights: [InspectorSectionID: CGFloat] = [:]
  }

  private func section(
    _ id: InspectorSectionID, sizing: InspectorSectionDescriptor.Sizing, probe: Probe
  ) -> InspectorSectionDescriptor {
    InspectorSectionDescriptor(
      id: id, title: id.rawValue, systemImage: "circle", sizing: sizing,
      content: AnyView(
        Color.clear.onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          probe.heights[id] = $0
        }))
  }

  /// Lays the stack out in a window that is never shown, until every section named has been
  /// drawn: no deadline of its own, the suite's time limit stops one that never is.
  private func draw(
    _ sections: [InspectorSectionDescriptor], layout: WorkspaceLayoutController, probe: Probe,
    height: CGFloat = 600, until drawn: [InspectorSectionID]
  ) async throws {
    let host = NSHostingView(
      rootView: InspectorSectionStack(sections: sections, layout: layout)
        .frame(width: 300, height: height))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    while !drawn.allSatisfy({ (probe.heights[$0] ?? 0) > 0 }) {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test("A section only declared is placed, sized and given its share, the layout untouched")
  func declaredSectionIsLaidOut() async throws {
    let probe = Probe()
    let fake = InspectorSectionID("test.fake")
    let layout = WorkspaceLayoutController()
    let sections = [
      section(.git, sizing: .fill(minimum: 120), probe: probe),
      section(.notes, sizing: .fill(minimum: 90), probe: probe),
      section(fake, sizing: .fill(minimum: 50), probe: probe),
    ]

    try await draw(sections, layout: layout, probe: probe, until: [.git, .notes, fake])

    let headers = 3 * InspectorSectionStack.headerHeight
    let handles = 2 * Double(SplitHandle.thickness)
    let total =
      (probe.heights[.git] ?? 0) + (probe.heights[.notes] ?? 0) + (probe.heights[fake] ?? 0)
    #expect(abs(Double(total) - (600 - headers - handles)) < 1)
    #expect((probe.heights[fake] ?? 0) >= 50)
    // After the sections declared before it: last.
    #expect(layout.inspectorSections.order(of: sections.map(\.id)).last == fake)
  }

  @Test("A folded section is not drawn, and gives its room to the others")
  func foldedSectionGivesWay() async throws {
    let probe = Probe()
    let layout = WorkspaceLayoutController()
    layout.setSectionCollapsed(.git, true)
    let sections = [
      section(.git, sizing: .fill(minimum: 120), probe: probe),
      section(.notes, sizing: .fill(minimum: 90), probe: probe),
    ]

    try await draw(sections, layout: layout, probe: probe, until: [.notes])

    #expect(probe.heights[.git] == nil)
    #expect(
      abs(Double(probe.heights[.notes] ?? 0) - (600 - 2 * InspectorSectionStack.headerHeight)) < 1)
  }

  @Test("A handle stops at the minimum of each section, and at the content of a fitting one")
  func handleRange() {
    let probe = Probe()
    let git = section(.git, sizing: .fill(minimum: 120), probe: probe)
    let notes = section(.notes, sizing: .fill(minimum: 90), probe: probe)
    let usage = section(.usage, sizing: .fitting(minimum: 60), probe: probe)

    #expect(
      InspectorSectionStack.range(above: git, below: notes, total: 400, contentHeights: [:])
        == 120...310)
    #expect(
      InspectorSectionStack.range(
        above: git, below: usage, total: 400, contentHeights: [.usage: 80])
        == 320...340)
    #expect(
      InspectorSectionStack.range(
        above: usage, below: git, total: 400, contentHeights: [.usage: 80])
        == 60...80)
  }
}
