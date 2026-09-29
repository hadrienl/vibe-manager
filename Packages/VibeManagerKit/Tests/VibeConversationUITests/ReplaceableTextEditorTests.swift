import AppKit
import SwiftUI
import Testing

@testable import VibeConversationUI

/// A text replaced under the field must not leave ⌘Z undoing edits it no longer holds: the first
/// such ⌘Z raised, and the next one aborted the application.
@MainActor
@Suite("A text editor whose text is replaced from outside", .timeLimit(.minutes(1)))
struct ReplaceableTextEditorTests {
  @Observable final class Draft {
    var text = ""
  }

  private struct Host: View {
    let draft: Draft
    let replaceable: Bool

    var body: some View {
      @Bindable var draft = draft
      if replaceable {
        ReplaceableTextEditor(text: $draft.text)
      } else {
        TextEditor(text: $draft.text)
      }
    }
  }

  /// Types into the field, in a window never shown, then lets `change` act on the draft; returns
  /// whether ⌘Z is still offered once SwiftUI has applied it.
  private func canUndo(replaceable: Bool, after change: (Draft) -> Void) async throws -> Bool {
    let draft = Draft()
    let host = NSHostingView(
      rootView: Host(draft: draft, replaceable: replaceable).frame(width: 300, height: 120))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let textView = try #require(Self.textView(in: host))
    window.makeFirstResponder(textView)
    let undoManager = try #require(textView.undoManager)
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    textView.insertText("a draft long enough", replacementRange: textView.selectedRange())
    textView.breakUndoCoalescing()
    undoManager.endUndoGrouping()
    // The field's own writing reaches the draft first, as it does when typed.
    while draft.text != "a draft long enough" { try await Task.sleep(for: .milliseconds(5)) }
    #expect(undoManager.canUndo)
    change(draft)
    while textView.string != draft.text {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(5))
    }
    // Once more, for what SwiftUI runs after the view took the text.
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    return undoManager.canUndo
  }

  private static func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    return view.subviews.lazy.compactMap(textView(in:)).first
  }

  @Test("A plain TextEditor keeps edits a replaced text no longer holds — the defect")
  func plainEditorKeepsStaleEdits() async throws {
    #expect(try await canUndo(replaceable: false) { $0.text = "" })
  }

  @Test("Emptied from outside, the field has nothing left to undo")
  func emptiedDropsUndo() async throws {
    #expect(try await !canUndo(replaceable: true) { $0.text = "" })
  }

  @Test("Added to from outside, the field has nothing left to undo")
  func appendedDropsUndo() async throws {
    #expect(try await !canUndo(replaceable: true) { $0.text += " and more" })
  }

  @Test("Typed into, the field keeps what ⌘Z undoes")
  func typingKeepsUndo() async throws {
    #expect(try await canUndo(replaceable: true) { _ in })
  }
}
