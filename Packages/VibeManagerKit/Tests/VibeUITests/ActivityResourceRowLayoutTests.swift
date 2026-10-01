import AppKit
import SwiftUI
import Testing
import VibeDomain

@testable import VibeUI

/// A resource of the Activity section is shown in full, never cut short (#279). Measured without
/// a window: nothing comes on screen.
@Suite("The height of a resource of the Activity section")
@MainActor
struct ActivityResourceRowLayoutTests {
  @Test("A long branch takes several lines at the column's narrowest, a short one does not")
  func longNameWraps() {
    let short = height(of: resource("main"), width: 260)
    let long = height(
      of: resource("feat/279-activite-sans-troncature-des-ressources-longues-et-illisibles"),
      width: 260)
    #expect(long >= short + 10)
    #expect(height(of: resource("main"), width: 420) == short)
  }

  private func height(of resource: SessionResource, width: Double) -> Double {
    let host = NSHostingController(rootView: ResourceRow(resource: resource))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }

  private func resource(_ name: String) -> SessionResource {
    SessionResource(
      key: "branch:/r/vibe-manager:\(name)", kind: .branch, label: name, context: "vibe-manager",
      target: .branch(repositoryPath: "/r/vibe-manager", webURL: nil), involvement: .created,
      firstSeenAt: Date())
  }
}
