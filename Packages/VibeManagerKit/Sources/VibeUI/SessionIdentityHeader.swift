import SwiftUI
import VibeApplication
import VibeDomain

/// The top of the inspector (#183): which session it describes, and where to rename it or change
/// its icon. Not a section: it is neither folded nor moved, and stays above them.
struct SessionIdentityHeader: View {
  let model: AppModel
  let session: WorkSession
  @State private var isHovering = false

  private var isRenaming: Bool {
    model.renaming == SessionIdentityEditing(sessionID: session.id, place: .inspector)
  }

  var body: some View {
    let appearance = model.displayedAppearance(of: session)
    HStack(alignment: .top, spacing: 10) {
      Button {
        model.beginAppearanceEditing(session.id, in: .inspector)
      } label: {
        SessionBadge(
          appearance: appearance, icon: model.icons.image(for: appearance.iconID), size: 32)
      }
      .buttonStyle(.plain)
      .disabled(!model.canEditIdentity(of: session.id))
      .help(Text("Change Icon", bundle: .module))
      .accessibilityLabel(Text("Change Icon", bundle: .module))
      .accessibilityIdentifier("inspector-session-badge")
      .sessionAppearancePopover(model: model, sessionID: session.id, place: .inspector)

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
            // On hover for the pointer; always there for VoiceOver and the keyboard.
            Button(action: rename) {
              Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help(Text("Rename", bundle: .module, comment: "Renames a session."))
            .accessibilityLabel(Text("Rename", bundle: .module, comment: "Renames a session."))
            .accessibilityIdentifier("inspector-session-rename")
          }
        }
        if let agent = session.agent {
          Text(AgentNaming.label(agent, names: model.agentNames))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(Text(verbatim: agent.providerID))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .onHover { isHovering = $0 }
  }

  private func rename() {
    model.beginRename(session.id, in: .inspector)
  }
}
