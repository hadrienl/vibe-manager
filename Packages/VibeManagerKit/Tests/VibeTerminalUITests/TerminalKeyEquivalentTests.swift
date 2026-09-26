import AppKit
import SwiftTerm
import Testing

@testable import VibeTerminalUI

@Suite("The menu's shortcuts before the terminal")
@MainActor
struct TerminalKeyEquivalentTests {
  private func key(
    _ characters: String, _ modifiers: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 13
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: keyCode)!
  }

  private func functionKey(_ scalar: Int) -> String {
    String(Character(Unicode.Scalar(UInt32(scalar))!))
  }

  /// A menu shaped like the application's: items at the top, in a submenu, and one disabled.
  private func makeMenu(_ target: MenuTarget) -> NSMenu {
    let main = NSMenu()
    main.autoenablesItems = false
    let session = NSMenu(title: "Session")
    session.autoenablesItems = false
    func add(
      _ menu: NSMenu, _ title: String, _ key: String, _ mask: NSEvent.ModifierFlags,
      enabled: Bool = true
    ) {
      let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: key)
      item.keyEquivalentModifierMask = mask
      item.target = target
      item.isEnabled = enabled
      menu.addItem(item)
    }
    add(session, "Close Session", "w", .command)
    add(session, "Close Window", "W", .command)
    add(session, "Restart", "r", [.command, .control])
    add(session, "Next", functionKey(NSDownArrowFunctionKey), [.command, .option])
    add(session, "Reload Page", "r", .command, enabled: false)
    let status = NSMenu(title: "Status")
    status.autoenablesItems = false
    add(status, "Next Status", functionKey(NSRightArrowFunctionKey), [.command, .option])
    let statusItem = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
    statusItem.submenu = status
    session.addItem(statusItem)
    let sessionItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
    sessionItem.submenu = session
    main.addItem(sessionItem)
    return main
  }

  private func setUp() -> (NSWindow, AccessibleTerminalView, other: NSView, SpyDelegate) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    let root = NSView(frame: window.contentLayoutRect)
    let terminal = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    let other = FocusableView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
    root.addSubview(terminal)
    root.addSubview(other)
    window.contentView = root
    let delegate = SpyDelegate()
    terminal.terminalDelegate = delegate
    window.makeFirstResponder(terminal)
    return (window, terminal, other, delegate)
  }

  @Test("The menu's shortcuts are found at every depth, with their exact modifiers")
  func findsShortcuts() {
    let target = MenuTarget()
    let menu = makeMenu(target)
    #expect(MenuKeyEquivalents.declares(key("w"), in: menu))
    #expect(MenuKeyEquivalents.declares(key("W", [.command, .shift]), in: menu))
    #expect(MenuKeyEquivalents.declares(key("w", [.command, .capsLock]), in: menu))
    #expect(MenuKeyEquivalents.declares(key("r", [.command, .control]), in: menu))
    #expect(MenuKeyEquivalents.declares(key("r"), in: menu))
    #expect(
      MenuKeyEquivalents.declares(
        key(functionKey(NSDownArrowFunctionKey), [.command, .option, .numericPad, .function]),
        in: menu))
    #expect(
      MenuKeyEquivalents.declares(
        key(functionKey(NSRightArrowFunctionKey), [.command, .option, .numericPad, .function]),
        in: menu))

    #expect(!MenuKeyEquivalents.declares(key("k"), in: menu))
    #expect(!MenuKeyEquivalents.declares(key("w", [.command, .option]), in: menu))
    #expect(!MenuKeyEquivalents.declares(key("r", [.command, .shift]), in: menu))
    #expect(target.ran.isEmpty)
  }

  @Test("⌘W with the keyboard in the terminal runs the menu's item, and the agent gets nothing")
  func menuRunsFirst() {
    let (_, terminal, _, delegate) = setUp()
    let target = MenuTarget()
    let menu = makeMenu(target)
    terminal.menuProvider = { menu }

    #expect(terminal.performKeyEquivalent(with: key("w")))
    #expect(target.ran == ["Close Session"])
    #expect(terminal.performKeyEquivalent(with: key("W", [.command, .shift])))
    #expect(target.ran == ["Close Session", "Close Window"])
    #expect(delegate.sent.isEmpty)
  }

  @Test("A disabled item swallows its shortcut: nothing runs, and nothing reaches the agent")
  func disabledItemSwallows() {
    let (_, terminal, _, delegate) = setUp()
    let target = MenuTarget()
    let menu = makeMenu(target)
    terminal.menuProvider = { menu }

    #expect(terminal.performKeyEquivalent(with: key("r")))
    #expect(target.ran.isEmpty)
    #expect(delegate.sent.isEmpty)
  }

  @Test("Under the kitty keyboard protocol too, the menu's shortcut never reaches the agent")
  func kittyProtocol() {
    let (_, terminal, _, delegate) = setUp()
    let target = MenuTarget()
    let menu = makeMenu(target)
    terminal.menuProvider = { menu }
    // What Claude Code and Codex send to turn the protocol on.
    terminal.feed(text: "\u{1B}[>31u")
    #expect(!terminal.getTerminal().keyboardEnhancementFlags.isEmpty)

    #expect(terminal.performKeyEquivalent(with: key("w")))
    #expect(terminal.performKeyEquivalent(with: key("r")))
    #expect(target.ran == ["Close Session"])
    #expect(delegate.sent.isEmpty)
  }

  @Test("A ⌘ key the menu does not have, and every key outside the terminal, is left alone")
  func leavesOtherKeys() {
    let (window, terminal, other, _) = setUp()
    let target = MenuTarget()
    let menu = makeMenu(target)
    terminal.menuProvider = { menu }

    #expect(!terminal.performKeyEquivalent(with: key("k")))
    #expect(!terminal.performKeyEquivalent(with: key("w", [])))
    window.makeFirstResponder(other)
    #expect(!terminal.performKeyEquivalent(with: key("w")))
    #expect(target.ran.isEmpty)
  }
}

@MainActor
private final class MenuTarget: NSObject {
  var ran: [String] = []

  @objc func run(_ sender: NSMenuItem) {
    ran.append(sender.title)
  }
}

private final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

private final class SpyDelegate: TerminalViewDelegate {
  var sent: [[UInt8]] = []

  func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func bell(source: TerminalView) {}
  func clipboardCopy(source: TerminalView, content: Data) {}
  func clipboardRead(source: TerminalView) -> Data? { nil }
  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
