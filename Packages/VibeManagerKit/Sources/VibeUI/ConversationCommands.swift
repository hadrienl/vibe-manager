import SwiftUI
import VibeConversationUI

/// Copy as Markdown in the Edit menu, beside Copy: the message whose text holds the keyboard, as
/// its context menu copies it.
public struct ConversationCopyCommands: Commands {
  public init() {}

  public var body: some Commands {
    CommandGroup(after: .pasteboard) {
      CopyAsMarkdownButton()
    }
  }
}

private struct CopyAsMarkdownButton: View {
  private let focused = FocusedMarkdown.shared

  var body: some View {
    Button(String(localized: "Copy as Markdown", bundle: .module)) {
      focused.copy()
    }
    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
    .disabled(focused.markdown == nil)
  }
}
