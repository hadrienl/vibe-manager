import SwiftUI
import VibeDomain

extension SessionInCreation {
  fileprivate var progressLabel: Text {
    switch phase {
    case .saving: Text("Creating the session…", bundle: .module)
    case .starting: Text("Starting the agent…", bundle: .module)
    }
  }
}

/// What the detail column shows between Create and the terminal: the session the user is going
/// to, drawn over the one they left so that nobody types into it believing it is the new one.
struct SessionCreationPlaceholder: View {
  let creation: SessionInCreation

  var body: some View {
    VStack(spacing: 14) {
      SessionBadge(appearance: creation.appearance, icon: creation.icon, size: 56)
      Text(creation.name)
        .font(.title2.weight(.semibold))
        .lineLimit(2)
        .multilineTextAlignment(.center)
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        creation.progressLabel
          .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    // Nothing under it answers a click or a key while it stands in for the new session.
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("session-creation-placeholder")
  }
}

/// The new session's place in the sidebar, before it has a row of its own. Not selectable: there
/// is nothing to select yet.
struct SessionCreationRow: View {
  let creation: SessionInCreation

  var body: some View {
    HStack(spacing: 10) {
      SessionBadge(appearance: creation.appearance, icon: creation.icon)
      VStack(alignment: .leading, spacing: 2) {
        Text(creation.name)
          .fontWeight(.medium)
          .lineLimit(1)
        Label {
          creation.progressLabel
        } icon: {
          ProgressView()
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 4)
    }
    .padding(.vertical, 4)
    .opacity(0.8)
    .selectionDisabled()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("session-creation-row")
  }
}
