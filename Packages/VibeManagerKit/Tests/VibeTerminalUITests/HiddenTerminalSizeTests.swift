import AppKit
import SwiftTerm
import Testing

@testable import VibeTerminalUI

/// A hidden terminal takes its new size once it settles, not at every step of a width that changes
/// under it (#150).
@Suite("The size of a hidden terminal", .timeLimit(.minutes(1)))
@MainActor
struct HiddenTerminalSizeTests {
  private func terminal(settleDelay: Duration = .seconds(3600)) -> AccessibleTerminalView {
    let view = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.settleDelay = settleDelay
    return view
  }

  /// What an animation does: a few points narrower at each frame.
  private func narrow(_ view: AccessibleTerminalView) {
    for width in stride(from: 790.0, through: 500, by: -10) {
      view.setFrameSize(NSSize(width: width, height: 600))
    }
  }

  @Test("A hidden terminal keeps its size through a burst, then takes the last one when shown")
  func waitsUntilShown() {
    let view = terminal()
    let columns = view.getTerminal().cols
    view.isHidden = true

    narrow(view)
    #expect(view.frame.size == NSSize(width: 800, height: 600))
    #expect(view.getTerminal().cols == columns)

    view.isHidden = false
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.getTerminal().cols < columns)
  }

  @Test("A hidden terminal takes the last size once it stops changing")
  func settlesWhileHidden() async throws {
    let view = terminal(settleDelay: .milliseconds(10))
    let columns = view.getTerminal().cols
    view.isHidden = true

    narrow(view)
    // Nothing ran between the steps: the burst was held back whole.
    #expect(view.frame.size == NSSize(width: 800, height: 600))

    // A state is waited for, not a deadline.
    while view.deferredSize != nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.isHidden)
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.getTerminal().cols < columns)
  }

  @Test("The end of a live resize gives a hidden terminal its size at once")
  func liveResizeEnds() {
    let view = terminal()
    view.isHidden = true
    narrow(view)
    view.viewDidEndLiveResize()
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.deferredSize == nil)
  }

  @Test("A terminal on screen follows its size at once")
  func shownFollows() {
    let view = terminal()
    let columns = view.getTerminal().cols
    view.setFrameSize(NSSize(width: 500, height: 600))
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.getTerminal().cols < columns)
  }

  /// A guard rather than a proof of the change: without any deferral this passes as well. It keeps
  /// the deferral from ever swallowing the first size, which a program needs to start.
  @Test("A terminal mounted hidden still takes its first size")
  func firstSizeWhileHidden() {
    let view = AccessibleTerminalView(frame: .zero)
    view.isHidden = true
    view.setFrameSize(NSSize(width: 800, height: 600))
    #expect(view.frame.size == NSSize(width: 800, height: 600))
    #expect(view.deferredSize == nil)
  }

  @Test("A size given back before it settles leaves nothing to apply")
  func sizeGivenBack() {
    let view = terminal()
    view.isHidden = true
    view.setFrameSize(NSSize(width: 500, height: 600))
    view.setFrameSize(NSSize(width: 800, height: 600))
    #expect(view.deferredSize == nil)
    view.isHidden = false
    #expect(view.frame.size == NSSize(width: 800, height: 600))
  }
}
