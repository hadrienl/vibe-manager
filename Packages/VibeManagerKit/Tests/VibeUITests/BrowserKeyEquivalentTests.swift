import AppKit
import Testing

@testable import VibeUI

@Suite("⌘W and ⌘T in the web view")
@MainActor
struct BrowserKeyEquivalentTests {
  private func commandW(_ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
    key("w", keyCode: 13, modifiers)
  }

  private func key(
    _ character: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: character, charactersIgnoringModifiers: character,
      isARepeat: false, keyCode: keyCode)!
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

    // ⇧⌘W is the session's, and a keyboard elsewhere leaves ⌘W to the menu.
    #expect(!container.performKeyEquivalent(with: commandW([.command, .shift])))
    window.makeFirstResponder(other)
    #expect(!container.performKeyEquivalent(with: commandW()))
    #expect(closed == 1)

    // The address bar is the web view's too.
    container.isAddressBarFocused = { true }
    #expect(container.performKeyEquivalent(with: commandW()))
    #expect(closed == 2)
  }

  @Test("⌘T opens a tab when the page or its address bar holds the keyboard, and nothing else")
  func opensTab() {
    let (window, container, page, other) = setUp()
    var opened = 0
    container.newTab = { opened += 1 }
    container.isAddressBarFocused = { false }

    window.makeFirstResponder(page)
    #expect(container.performKeyEquivalent(with: key("t", keyCode: 17)))
    #expect(opened == 1)

    #expect(!container.performKeyEquivalent(with: key("t", keyCode: 17, [.command, .option])))
    window.makeFirstResponder(other)
    #expect(!container.performKeyEquivalent(with: key("t", keyCode: 17)))
    #expect(opened == 1)

    container.isAddressBarFocused = { true }
    #expect(container.performKeyEquivalent(with: key("t", keyCode: 17)))
    #expect(opened == 2)
  }
}

private final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
