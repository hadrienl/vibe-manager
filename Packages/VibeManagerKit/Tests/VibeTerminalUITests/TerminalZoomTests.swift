import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

private actor SilentSupervisor: TerminalSupervisor {
  /// Never asked: the surfaces of these tests are given no session.
  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    throw CancellationError()
  }

  func session(for id: TerminalID) -> (any TerminalSession)? { nil }
  func stop(id: TerminalID, gracePeriod: Duration) {}
  func stopAll(gracePeriod: Duration) {}
}

/// The application's zoom reaches its terminals (#229).
@Suite("The zoom of the terminals", .timeLimit(.minutes(1)))
@MainActor
struct TerminalZoomTests {
  @Test("A bigger text gives the terminal fewer cells, in the same face")
  func biggerTextFewerCells() {
    let view = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let face = view.font.fontName
    let columns = view.getTerminal().cols

    view.applyFontSize(18)

    #expect(view.font.pointSize == 18)
    #expect(view.font.fontName == face)
    #expect(view.getTerminal().cols < columns)
  }

  @Test("A zoom reads the terminal's text again for VoiceOver, its cells being others (#226)")
  func zoomRefreshesTheAccessibleText() {
    let view = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    _ = view.accessibleText
    let builds = view.textBuilds

    _ = view.accessibleText
    #expect(view.textBuilds == builds)

    view.applyFontSize(18)
    _ = view.accessibleText
    #expect(view.textBuilds == builds + 1)
  }

  private func pane() -> TerminalPaneModel {
    TerminalPaneModel(
      terminalID: TerminalID(),
      supervisor: SilentSupervisor(),
      spec: TerminalSpec(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      ),
      viewportTimeout: .zero
    )
  }

  private func surface(_ pane: TerminalPaneModel, size: Double) -> AnyView {
    AnyView(
      TerminalSurface(pane: pane, session: nil, isActive: false)
        .environment(\.terminalFontSize, size))
  }

  /// A window never put on screen: enough for the view to be made and updated.
  private func host(_ view: AnyView) -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return host
  }

  @Test("The terminal of the window takes the size the environment gives")
  func environmentReachesTheTerminal() throws {
    let host = host(surface(pane(), size: 18))

    let terminal = try #require(Self.terminal(in: host))
    #expect(terminal.font.pointSize == 18)
  }

  @Test("A terminal already open follows the zoom, in the same view")
  func openTerminalFollows() throws {
    let pane = pane()
    let host = host(surface(pane, size: 13))
    let terminal = try #require(Self.terminal(in: host))
    let columns = terminal.getTerminal().cols
    #expect(terminal.font.pointSize == 13)

    host.rootView = surface(pane, size: 16)
    host.layoutSubtreeIfNeeded()

    #expect(Self.terminal(in: host) === terminal)
    #expect(terminal.font.pointSize == 16)
    #expect(terminal.getTerminal().cols < columns)
  }

  private static func terminal(in view: NSView) -> TerminalView? {
    if let terminal = view as? TerminalView { return terminal }
    for subview in view.subviews {
      if let found = terminal(in: subview) { return found }
    }
    return nil
  }
}
