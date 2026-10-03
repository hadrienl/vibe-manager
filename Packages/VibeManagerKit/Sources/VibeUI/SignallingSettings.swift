import AppKit
import SwiftUI
import VibeApplication

/// How the requests of background sessions are signalled (#40, #41): the floating panel first,
/// since it is the heart of the feature, then the notifications and the palette.
struct SignallingSettings: View {
  @Bindable var model: AppModel
  @State private var isAuthorized: Bool?

  var body: some View {
    Form {
      if let panel = model.floatingPanel {
        FloatingPanelSettingsSection(panel: panel, avatars: model.avatars) {
          manageAvatars()
        }
      }
      notifications
      Section {
        Toggle(isOn: $model.showsRequestDockBadge) {
          Text("Show the number of requests on the Dock icon", bundle: .module)
        }
        Toggle(isOn: $model.expandsPaletteOnRequest) {
          Text("Unfold the palette when a request arrives", bundle: .module)
          Text(
            "Folded, the palette shows how many requests wait, and VoiceOver says each one.",
            bundle: .module)
        }
      } header: {
        Text("Palette", bundle: .module, comment: "A section of the Settings window.")
      }
    }
    .formStyle(.grouped)
    .task { isAuthorized = await model.requestNotifier?.isAuthorized() }
  }

  /// "Manage Avatars…": the page of the avatars, reached from this one.
  func manageAvatars() {
    model.settingsPage = .avatars
  }

  /// While the floating panel is on, no notification is posted (ADR 0029).
  var notificationsAreReplaced: Bool {
    model.floatingPanel?.isEnabled ?? false
  }

  /// The notifications: greyed out, and the section says why, while the floating panel replaces
  /// them.
  private var notifications: some View {
    let isReplaced = notificationsAreReplaced
    return Section {
      Group {
        Toggle(isOn: $model.notifiesRequests) {
          Text("Notify me of requests and replies", bundle: .module)
          Text(
            "Also when an agent stops. Only while Vibe Manager is not in front.",
            bundle: .module)
        }
        Picker(selection: $model.requestNotificationContent) {
          Text("The kind of request", bundle: .module).tag(RequestNotificationContent.kind)
          Text("The command or the question", bundle: .module).tag(
            RequestNotificationContent.detail)
        } label: {
          Text("Notifications show", bundle: .module)
          Text(
            "Either way, the lock screen shows only that a request arrived.", bundle: .module)
        }
        .disabled(!model.notifiesRequests)
        if isAuthorized == false, model.notifiesRequests {
          LabeledContent {
            Button {
              Self.openNotificationSettings()
            } label: {
              Text("Open System Settings…", bundle: .module)
            }
          } label: {
            Label {
              Text("Notifications are turned off for Vibe Manager.", bundle: .module)
            } icon: {
              Image(systemName: "bell.slash")
            }
          }
        }
      }
      .disabled(isReplaced)
      // Greyed out, a control says why to VoiceOver as well.
      .accessibilityHint(isReplaced ? Self.replacedReason : Text(verbatim: ""))
    } header: {
      Text("Notifications", bundle: .module, comment: "A section of the Settings window.")
    } footer: {
      if isReplaced {
        Self.replacedReason
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Why the notifications are greyed out.
  private static var replacedReason: Text {
    Text(
      "The floating panel presents the requests: no notification is posted while it is on.",
      bundle: .module)
  }

  static func openNotificationSettings() {
    let identifier = Bundle.main.bundleIdentifier ?? ""
    if let url = URL(
      string:
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)")
    {
      // Opens outside: the constant address of System Settings' notifications.
      NSWorkspace.shared.open(url)
    }
  }
}

/// The floating panel, in Settings › Notifications (#41): on or off, the avatar that presents
/// the requests, what it does with none, its shortcut and its place.
struct FloatingPanelSettingsSection: View {
  @Bindable var panel: FloatingRequestPanelModel
  /// The library the avatar is chosen from; without it, the row is not shown.
  let avatars: AvatarLibraryModel?
  /// Turns to the page of the avatars.
  let manageAvatars: () -> Void

  var body: some View {
    Section {
      Toggle(isOn: $panel.isEnabled) {
        Text("Show requests above other applications", bundle: .module)
        Text(
          "When Vibe Manager is not in front, an avatar presents the requests in a bubble. Notifications are then not needed.",
          bundle: .module)
      }
      .accessibilityIdentifier("floating-panel-toggle")
      if let avatars {
        AvatarInUseRow(avatars: avatars, manage: manageAvatars)
      }
      Picker(selection: $panel.idle) {
        Text("Hide the panel", bundle: .module).tag(FloatingPanelIdle.hidden)
        Text("Keep the avatar on screen", bundle: .module).tag(FloatingPanelIdle.avatarOnly)
      } label: {
        Text("With no pending request", bundle: .module)
      }
      .disabled(!panel.isEnabled)
      LabeledContent {
        Text(verbatim: "⌃⌥⌘P")
          .monospaced()
      } label: {
        Text("Shortcut", bundle: .module)
        Text("Reaches the bubble from any application.", bundle: .module)
      }
      LabeledContent {
        Button {
          panel.resetPositions()
        } label: {
          Text("Put Back in Place", bundle: .module)
        }
      } label: {
        Text("Position", bundle: .module)
        Text("The avatar goes back to the bottom right corner of each screen.", bundle: .module)
      }
      .disabled(!panel.isEnabled)
    } header: {
      Text("Floating Panel", bundle: .module, comment: "A section of the Settings window.")
    }
  }
}

/// The avatar the floating panel shows: its picture, a menu of the avatars kept — drafts are not
/// ready to be used — and the way to the page that makes them.
///
/// Choosing one here is the same as "Use This Avatar" on the page of the avatars: the panel
/// changes at once.
struct AvatarInUseRow: View {
  let avatars: AvatarLibraryModel
  let manage: () -> Void

  /// The widest the menu grows: a name has up to 60 characters, and the row must stay whole.
  private static let menuWidth: CGFloat = 240

  /// A row of its own rather than a `LabeledContent`: with its three controls, the form would lay
  /// them under the label. Here the explanation wraps first, and the controls stay beside it.
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      controls
      // The avatar chosen could not be put in the panel: said here, where it was chosen.
      if avatars.problem == .using {
        Label {
          Text(AvatarPresentation.message(for: .using))
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .font(.callout)
        .accessibilityIdentifier("avatar-in-use-problem")
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Avatar", bundle: .module, comment: "The avatar of the floating panel.")
        Self.explanation
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // The menu says it for VoiceOver: "Avatar", the one in use, and this explanation as its
      // hint. Read here as well, the row would say it twice.
      .accessibilityHidden(true)
      AvatarView(images: avatars.inUseImages, expression: .neutral, size: 26)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
      Picker(selection: inUse) {
        ForEach(choices) { entry in
          Text(verbatim: DisplaySafeText.visible(AvatarLibraryModel.name(of: entry)))
            .tag(entry.id)
            // A kept avatar that cannot be read, or lacks expressions, cannot be used.
            .selectionDisabled(entry.problem != nil)
        }
      } label: {
        Text("Avatar", bundle: .module, comment: "The avatar of the floating panel.")
      }
      .labelsHidden()
      .frame(maxWidth: Self.menuWidth)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      .accessibilityHint(Self.explanation)
      .accessibilityIdentifier("avatar-in-use-picker")
      Button {
        manage()
      } label: {
        Text("Manage Avatars…", bundle: .module)
      }
      .fixedSize()
      .layoutPriority(1)
      .accessibilityIdentifier("manage-avatars")
    }
  }

  private static var explanation: Text {
    Text("The one that presents the requests. Others are made in Avatars.", bundle: .module)
  }

  /// The avatars that can be chosen: the default one first, then those kept, never a draft.
  var choices: [AvatarLibraryEntry] {
    avatars.entries.filter { !$0.isDraft }
  }

  var inUse: Binding<AvatarID> {
    Binding(
      get: { avatars.inUse },
      set: { id in
        // The model says to VoiceOver that it is in use, or why it is not.
        Task { await avatars.use(id) }
      })
  }
}
