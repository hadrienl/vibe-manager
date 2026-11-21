import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// Where a session is renamed, or given another icon or theme, when the sidebar does not show its
/// row (#183, #578): the sidebar hidden, the session in another column, or archived. Shown above
/// the session for as long as it is edited, from the menu bar or the archive's menu.
struct SessionIdentityBar: View {
  let model: AppModel
  let session: WorkSession
  @State private var isHovering = false
  @FocusState private var isRenameFocused: Bool

  private var isRenaming: Bool {
    model.renaming == SessionIdentityEditing(sessionID: session.id, place: .detail)
  }

  var body: some View {
    let appearance = model.displayedAppearance(of: session)
    HStack(alignment: .top, spacing: 10) {
      Button {
        model.beginAppearanceEditing(session.id, in: .detail)
      } label: {
        SessionBadge(
          appearance: appearance, icon: model.icons.image(for: appearance.iconID), size: 32)
      }
      .buttonStyle(.plain)
      .disabled(!model.canEditIdentity(of: session.id))
      .instantTooltip(Text("Change Icon", bundle: .module))
      .accessibilityLabel(Text("Change Icon", bundle: .module))
      .accessibilityIdentifier("detail-session-badge")
      .sessionAppearancePopover(model: model, sessionID: session.id, place: .detail)

      VStack(alignment: .leading, spacing: 2) {
        if isRenaming {
          SessionNameField(
            model: model, session: session, font: NSFont.preferredFont(forTextStyle: .headline))
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(session.name)
              .font(.headline)
              .lineLimit(2)
              .onTapGesture(count: 2) { rename() }
            // On hover for the pointer; always there for VoiceOver and the keyboard, and seen
            // when the keyboard is on it (#230).
            Button(action: rename) {
              Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .focused($isRenameFocused)
            .opacity(isHovering || isRenameFocused ? 1 : 0)
            .instantTooltip(Text("Rename", bundle: .module, comment: "Renames a session."))
            .accessibilityLabel(Text("Rename", bundle: .module, comment: "Renames a session."))
            .accessibilityIdentifier("detail-session-rename")
          }
        }
        if let agent = session.agent {
          Text(AgentNaming.label(agent, names: model.agentNames))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .instantTooltip(Text(verbatim: agent.providerID))
        }
        themeButton
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .onHover { isHovering = $0 }
  }

  /// The theme of the session's conversation (#274), and where to change it.
  private var themeButton: some View {
    let themes = model.conversations.themes
    let theme = model.displayedConversationTheme(of: session)
    let isMissing = theme.map { themes.theme($0) == nil } ?? false
    let name = SessionThemeText.name(of: theme, themes: themes)
    return Button {
      model.beginThemeEditing(session.id, in: .detail)
    } label: {
      Label {
        name
      } icon: {
        Image(systemName: isMissing ? "exclamationmark.triangle" : "paintpalette")
      }
      .font(.callout)
      .foregroundStyle(isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
      .lineLimit(1)
    }
    .buttonStyle(.plain)
    .disabled(!model.canEditIdentity(of: session.id))
    .instantTooltip(Text("Change Conversation Theme", bundle: .module))
    .accessibilityLabel(Text("Conversation Theme: \(name)", bundle: .module))
    .accessibilityIdentifier("detail-session-theme")
    .sessionThemePopover(model: model, sessionID: session.id, place: .detail)
  }

  private func rename() {
    model.beginRename(session.id, in: .detail)
  }
}
