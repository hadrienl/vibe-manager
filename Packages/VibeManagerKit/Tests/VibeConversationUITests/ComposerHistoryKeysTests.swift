import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The composer itself, in a window never put on screen, given ↑, ↓ and Escape as the keyboard
/// gives them (#123).
@MainActor
@Suite("↑ and ↓ in the composer recall the messages sent", .serialized, .timeLimit(.minutes(1)))
struct ComposerHistoryKeysTests {
  @MainActor private final class Composer {
    let model: ConversationModel
    let window: NSWindow
    let textView: NSTextView

    init(prompts: [String]) async throws {
      model = ConversationModel(sessionID: SessionID())
      model.write = { _ in }
      model.processRunning = { true }
      model.apply(
        ConversationSnapshot(
          entries: prompts.map {
            ConversationEntry(id: $0, content: .userPrompt($0, attachments: 0))
          }, availability: .available))
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: PromptComposer(model: model))
      window.layoutIfNeeded()
      textView = try #require(Self.textView(in: window.contentView))
      window.makeFirstResponder(textView)
      let window = window
      PromptComposer.focusedTextView = { window.firstResponder as? NSTextView }
    }

    private static func textView(in view: NSView?) -> NSTextView? {
      guard let view else { return nil }
      return view as? NSTextView ?? view.subviews.lazy.compactMap(textView(in:)).first
    }

    /// Types `text` as the user would, the cursor left at `cursor` (its end by default).
    func type(_ text: String, cursor: Int? = nil) async {
      textView.selectAll(nil)
      textView.insertText(text, replacementRange: textView.selectedRange())
      await until { self.model.draft == text }
      textView.setSelectedRange(NSRange(location: cursor ?? (text as NSString).length, length: 0))
    }

    func press(_ key: UInt16, _ character: Int, modifiers: NSEvent.ModifierFlags = []) async {
      let characters = String(Character(UnicodeScalar(UInt32(character))!))
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)
        window.sendEvent(event!)
      }
      // The handler runs within the event; what it asks of the next turn, just after.
      for _ in 0..<5 { await Task.yield() }
    }

    func up(_ modifiers: NSEvent.ModifierFlags = []) async {
      await press(126, NSUpArrowFunctionKey, modifiers: modifiers)
    }
    func down() async { await press(125, NSDownArrowFunctionKey) }
    func escape() async { await press(53, 0x1B) }

    /// Waits for a state, never for a delay: a runner may stall for seconds.
    func until(_ condition: @escaping () -> Bool) async {
      while !condition() { await Task.yield() }
    }

    var cursor: Int { textView.selectedRange().location }

    func close() {
      PromptComposer.focusedTextView = { NSApp.keyWindow?.firstResponder as? NSTextView }
      window.contentView = nil
      window.close()
    }
  }

  @Test("↑ recalls the last message then the one before, the cursor at its end; ↓ comes back")
  func upAndDown() async throws {
    let composer = try await Composer(prompts: ["first", "second message"])
    defer { composer.close() }
    await composer.type("draft")
    await composer.up()
    await composer.until { composer.textView.string == "second message" }
    await composer.until { composer.cursor == ("second message" as NSString).length }
    await composer.up()
    await composer.until { composer.model.draft == "first" }
    await composer.down()
    await composer.down()
    await composer.until { composer.model.draft == "draft" }
  }

  @Test("Away from the first line, or with a modifier, ↑ only moves the cursor")
  func movesTheCursor() async throws {
    let composer = try await Composer(prompts: ["earlier"])
    defer { composer.close() }
    await composer.type("one\ntwo")
    await composer.up()
    #expect(composer.model.draft == "one\ntwo")
    #expect(composer.cursor <= 3)
    await composer.type("one", cursor: 3)
    await composer.up(.shift)
    #expect(composer.model.draft == "one")
  }

  @Test("Escape gives the draft back")
  func escape() async throws {
    let composer = try await Composer(prompts: ["earlier"])
    defer { composer.close() }
    await composer.type("draft")
    await composer.up()
    await composer.until { composer.model.draft == "earlier" }
    await composer.escape()
    await composer.until { composer.model.draft == "draft" }
  }
}
