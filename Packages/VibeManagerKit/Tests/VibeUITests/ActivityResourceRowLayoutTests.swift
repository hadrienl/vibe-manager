import AppKit
import SwiftUI
import Testing
import VibeDomain

@testable import VibeUI

/// A resource of the Activity section is shown in full, never cut short (#279). Measured in a
/// sidebar list, as the pane shows it — such a list keeps a text to one line unless told otherwise
/// — in a window that never comes on screen.
@Suite("The height of a resource of the Activity section")
@MainActor
struct ActivityResourceRowLayoutTests {
  @Test("A long branch takes several lines at the column's narrowest, a short one does not")
  func longNameWraps() {
    let long = resource("feat/279-activite-sans-troncature-des-ressources-longues-et-illisibles")
    let heights = rowHeights([resource("main"), long], width: 260)
    #expect(heights.count == 2)
    guard heights.count == 2 else { return }
    #expect(heights[1] >= heights[0] + 10)
    #expect(rowHeights([resource("main")], width: 420) == [heights[0]])
  }

  private func rowHeights(_ resources: [SessionResource], width: Double) -> [Double] {
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: 0, width: width, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    // Owned by this test, not by AppKit: a window made in code releases itself when closed.
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: List {
        ForEach(resources) { ResourceRow(resource: $0) }
      }
      .listStyle(.sidebar)
      .frame(width: width, height: 400))
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    // Until every row is there and two passes agree on their heights, never for a set time: a
    // busy runner lays the list out late.
    var heights: [Double] = []
    let limit = Date().addingTimeInterval(10)
    while Date() < limit {
      host.layoutSubtreeIfNeeded()
      let current = tableView(in: host).map { table in
        (0..<table.numberOfRows).map { Double(table.rect(ofRow: $0).height) }
      }
      if let current, current.count == resources.count, current == heights { return heights }
      heights = current ?? []
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return heights
  }

  private func tableView(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view.subviews.lazy.compactMap { tableView(in: $0) }.first
  }

  private func resource(_ name: String) -> SessionResource {
    SessionResource(
      key: "branch:/r/vibe-manager:\(name)", kind: .branch, label: name, context: "vibe-manager",
      target: .branch(repositoryPath: "/r/vibe-manager", webURL: nil), involvement: .created,
      firstSeenAt: Date())
  }
}
