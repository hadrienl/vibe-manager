import AppKit
import SwiftUI
import VibeApplication

/// The pages of Settings › Requests (#154).
public enum RequestsPane: String, Hashable, Sendable, CaseIterable {
  /// How the requests are signalled: the floating panel, the notifications, the palette.
  case signalling
  /// The avatars of the floating panel.
  case avatars

  /// The label of the page in the segmented control.
  var title: LocalizedStringResource {
    switch self {
    case .signalling:
      LocalizedStringResource(
        "Alerts", bundle: .module,
        comment: "A page of Settings › Requests: how requests are signalled.")
    case .avatars:
      LocalizedStringResource(
        "Avatars", bundle: .module,
        comment: "A page of Settings › Requests: the avatars of the floating panel.")
    }
  }
}

/// Settings › Requests (#154): how the requests are signalled, and the avatars that present them,
/// in two pages under a segmented control.
///
/// Both pages have the same size, so that the window does not jump from one to the other. Wider
/// than the settings' form, and under the widest tabs: nothing is cut (principle 2 of #154).
struct RequestsSettingsView: View {
  @Bindable var model: AppModel

  /// The size of each page, under the segmented control.
  ///
  /// 700 points high rather than the 620 of the design of #154: the alerts need 673 in French
  /// with the panel on, 691 with the notifications refused by the system, and at 620 the palette
  /// fell under the fold of a form whose scroller is hidden.
  nonisolated static let pageSize = CGSize(width: 900, height: 700)

  var body: some View {
    VStack(spacing: 0) {
      if model.avatars != nil {
        Picker(selection: $model.requestsPane) {
          ForEach(RequestsPane.allCases, id: \.self) { pane in
            Text(pane.title).tag(pane)
          }
        } label: {
          Text("Requests Section", bundle: .module, comment: "The pages of Settings › Requests.")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, 10)
        .accessibilityIdentifier("requests-pane")
        Divider()
      }
      page
        .frame(width: Self.pageSize.width, height: Self.pageSize.height)
    }
    // Once each time the tab appears, for both pages: the avatars made or deleted meanwhile.
    .task { await model.avatars?.refresh() }
  }

  @ViewBuilder
  private var page: some View {
    if model.requestsPane == .avatars, let avatars = model.avatars {
      AvatarLibraryView(avatars: avatars)
    } else {
      SignallingSettings(model: model)
    }
  }
}

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
    // The size of the page: with the panel on and its reason shown, the form may scroll.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { isAuthorized = await model.requestNotifier?.isAuthorized() }
  }

  /// "Manage Avatars…": the other page of the tab.
  func manageAvatars() {
    model.requestsPane = .avatars
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
          Text("Notify me of requests", bundle: .module)
          Text(
            "When an agent in the background asks for something, replies or stops, while Vibe Manager is not in front.",
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

/// The floating panel, in Settings › Requests › Alerts (#41): on or off, the avatar that presents
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
