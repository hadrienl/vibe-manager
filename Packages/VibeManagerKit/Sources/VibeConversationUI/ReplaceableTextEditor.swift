import SwiftUI

/// A `TextEditor` whose text is also changed from outside: a draft emptied once sent, a summary
/// generated again.
///
/// The text view records each edit for ⌘Z by where it is in the text, and never learns of a text
/// replaced under it. The records left then point past the end of the new one: the next ⌘Z raises,
/// AppKit swallows the exception with an undo group left open, and the ⌘Z after that — anywhere in
/// the window, the web view included — aborts the application. A text that does not come from the
/// field therefore drops what the window's undo manager holds.
public struct ReplaceableTextEditor: View {
  @Binding private var text: String
  @Environment(\.undoManager) private var undoManager
  /// What the field itself last wrote: any other text was set from outside.
  @State private var typed: String?

  public init(text: Binding<String>) {
    _text = text
  }

  public var body: some View {
    TextEditor(
      text: Binding(
        get: { text },
        set: {
          typed = $0
          text = $0
        })
    )
    .onChange(of: text) { _, text in
      guard text != typed else { return }
      typed = text
      undoManager?.removeAllActions()
    }
  }
}
