import AppKit
import Testing

@testable import VibeUI

@Suite("⌘W in the web view")
@MainActor
struct BrowserKeyEquivalentTests {
  private func commandW(_ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
      keyCode: 13)!
  }

  private func setUp() -> (NSWindow, BrowserWebViewContainer, page: NSView, other: NSView) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    let root = NSView(frame: window.contentLayoutRect)
    let container = BrowserWebViewContainer(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    let page = FocusableView(frame: container.bounds)
    let other = FocusableView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
    container.addSubview(page)
    root.addSubview(container)
    root.addSubview(other)
    window.contentView = root
    return (window, container, page, other)
  }

  @Test("It closes the tab when the page holds the keyboard, and nothing else")
  func closesTab() {
    let (window, container, page, other) = setUp()
    var closed = 0
    container.closeTab = { closed += 1 }
    container.isAddressBarFocused = { false }

    window.makeFirstResponder(page)
    #expect(container.performKeyEquivalent(with: commandW()))
    #expect(closed == 1)

    // ⇧⌘W is the window's, and a keyboard elsewhere leaves ⌘W to the session.
    #expect(!container.performKeyEquivalent(with: commandW([.command, .shift])))
    window.makeFirstResponder(other)
    #expect(!container.performKeyEquivalent(with: commandW()))
    #expect(closed == 1)

    // The address bar is the web view's too.
    container.isAddressBarFocused = { true }
    #expect(container.performKeyEquivalent(with: commandW()))
    #expect(closed == 2)
  }
}

private final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
