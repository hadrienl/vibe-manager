import SwiftUI
import VibeConversationUI
import VibeDomain

/// The conversation theme chosen in the Change Theme popover (#274): shown in the session's
/// conversation while it is open, written when it closes, dropped by Escape.
public struct SessionThemeEditing: Hashable, Sendable {
  public let editing: SessionIdentityEditing
  /// The session's theme when the popover opened.
  public let original: String?
  /// The card chosen, `nil` following the settings.
  public var current: String?

  public init(editing: SessionIdentityEditing, original: String?) {
    self.editing = editing
    self.original = original
    current = original
  }

  public var hasChanges: Bool { current != original }
}

/// The popover's content: the picker, and what the card chosen means.
struct SessionThemePopover: View {
  let model: AppModel
  let editing: SessionThemeEditing

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Conversation Theme", bundle: .module)
        .font(.headline)
      ConversationThemePicker(
        selection: Binding(get: { editing.current }, set: { model.previewTheme($0) }),
        themes: model.conversations.themes, appearance: model.conversations.appearance,
        nilTitle: SessionThemeText.followsSettings,
        commit: { model.endThemeEditing() }, cancel: { model.cancelThemeEditing() })
      SessionThemeText.caption(for: editing.current, themes: model.conversations.themes)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 332, alignment: .leading)
    }
    .padding(16)
  }
}

/// The words around a session's theme, the same wherever it is chosen.
@MainActor
enum SessionThemeText {
  static var followsSettings: Text {
    Text(
      "Follow Settings", bundle: .module,
      comment: "A session's conversation theme: none of its own.")
  }

  /// What the theme chosen does to the conversation.
  static func caption(for theme: String?, themes: ConversationThemesModel) -> Text {
    guard let theme else {
      return Text("Follows Settings › Conversation, in light and dark mode.", bundle: .module)
    }
    guard themes.theme(theme) != nil else {
      return Text(
        "This theme was deleted or can no longer be read: the conversation follows the settings.",
        bundle: .module)
    }
    return Text("This theme applies as it is, in light and dark mode.", bundle: .module)
  }

  /// The theme's name, as the inspector shows it.
  static func name(of theme: String?, themes: ConversationThemesModel) -> Text {
    guard let theme else { return followsSettings }
    guard let found = themes.theme(theme) else { return Text("Theme Not Found", bundle: .module) }
    return Text(verbatim: found.displayName)
  }
}

extension View {
  /// The Change Theme popover, on the place of the session it edits.
  func sessionThemePopover(
    model: AppModel, sessionID: SessionID, place: SessionIdentityEditing.Place
  ) -> some View {
    let editing = SessionIdentityEditing(sessionID: sessionID, place: place)
    return popover(
      isPresented: Binding(
        get: { model.themeEditing?.editing == editing },
        set: { isPresented in
          // Closed by a click elsewhere: what was chosen is kept. Escape has already let it go.
          if !isPresented, model.themeEditing?.editing == editing {
            model.endThemeEditing()
          }
        }),
      arrowEdge: .trailing
    ) {
      if let themeEditing = model.themeEditing, themeEditing.editing == editing {
        SessionThemePopover(model: model, editing: themeEditing)
      }
    }
  }
}
