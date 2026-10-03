import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminalUI

private actor SilentSession: TerminalSession {
  nonisolated let id: TerminalID

  init(id: TerminalID) {
    self.id = id
  }

  func attach() -> TerminalAttachment {
    TerminalAttachment(
      state: .running(processIdentifier: 7),
      history: TerminalHistorySnapshot(bytes: [], droppedByteCount: 0),
      events: AsyncStream { $0.finish() }
    )
  }

  func state() -> TerminalProcessState { .running(processIdentifier: 7) }
  func history() -> TerminalHistorySnapshot {
    TerminalHistorySnapshot(bytes: [], droppedByteCount: 0)
  }
  func write(_ bytes: [UInt8]) {}
  func resize(to size: TerminalSize) {}
  func stop(gracePeriod: Duration) {}
  func kill() {}
}

private actor SilentSupervisor: TerminalSupervisor {
  func start(_ spec: TerminalSpec, for id: TerminalID) throws -> any TerminalSession {
    SilentSession(id: id)
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

  @Test("The terminal of the window takes the size the environment gives")
  func environmentReachesTheTerminal() throws {
    let pane = TerminalPaneModel(
      terminalID: TerminalID(),
      supervisor: SilentSupervisor(),
      spec: TerminalSpec(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      ),
      viewportTimeout: .zero
    )
    let host = NSHostingView(
      rootView: TerminalSurface(pane: pane, session: nil, isActive: false)
        .environment(\.terminalFontSize, 18)
    )
    // Never put on screen: a window is enough for the view to be made and updated.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    let terminal = try #require(Self.terminal(in: host))
    #expect(terminal.font.pointSize == 18)
  }

  private static func terminal(in view: NSView) -> TerminalView? {
    if let terminal = view as? TerminalView { return terminal }
    for subview in view.subviews {
      if let found = terminal(in: subview) { return found }
    }
    return nil
  }
}
