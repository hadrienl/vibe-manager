import AppKit
import SwiftTerm
import Testing

@testable import VibeTerminalUI

/// A hidden terminal takes its new size when it is shown, not at every step of a width that
/// changes under it (#150).
@Suite("The size of a hidden terminal")
@MainActor
struct HiddenTerminalSizeTests {
  private func terminal() -> AccessibleTerminalView {
    AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  }

  @Test("A hidden terminal keeps its size, then takes the last one it was given when shown")
  func waitsUntilShown() {
    let view = terminal()
    let columns = view.getTerminal().cols
    view.isHidden = true

    for width in stride(from: 790.0, through: 500, by: -10) {
      view.setFrameSize(NSSize(width: width, height: 600))
    }
    #expect(view.frame.size == NSSize(width: 800, height: 600))
    #expect(view.getTerminal().cols == columns)

    view.isHidden = false
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.getTerminal().cols < columns)
  }

  @Test("A terminal on screen follows its size at once")
  func shownFollows() {
    let view = terminal()
    let columns = view.getTerminal().cols
    view.setFrameSize(NSSize(width: 500, height: 600))
    #expect(view.frame.size == NSSize(width: 500, height: 600))
    #expect(view.getTerminal().cols < columns)
  }

  @Test("A terminal mounted hidden still takes its first size")
  func firstSizeWhileHidden() {
    let view = AccessibleTerminalView(frame: .zero)
    view.isHidden = true
    view.setFrameSize(NSSize(width: 800, height: 600))
    #expect(view.frame.size == NSSize(width: 800, height: 600))
  }

  @Test("A size given back before the terminal is shown leaves nothing to apply")
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
