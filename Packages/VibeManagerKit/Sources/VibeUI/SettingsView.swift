import SwiftUI
import VibeApplication

/// The application's settings.
///
/// Both lines are ways back to a question asked once. The Full Disk Access step at launch is never
/// asked again, and neither is the close confirmation once "Don't ask again" was ticked: refusing
/// either must not be a door that closes, so this is where the user finds the question again.
public struct SettingsView: View {
  private let permissions: PermissionsModel?
  private let model: AppModel?

  public init(permissions: PermissionsModel? = nil, model: AppModel? = nil) {
    self.permissions = permissions
    self.model = model
  }

  public var body: some View {
    Form {
      if let model {
        Section("Sessions") {
          SessionCloseRow(model: model)
        }
      }
      Section("Privacy") {
        if let permissions {
          FullDiskAccessRow(permissions: permissions)
        } else {
          Text("File access cannot be read in this window.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .task { await permissions?.recheck() }
  }
}

private struct FullDiskAccessRow: View {
  let permissions: PermissionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Full Disk Access") {
        Label(label, systemImage: symbolName)
          .foregroundStyle(permissions.isGranted ? .secondary : .primary)
      }

      if permissions.status == .notGranted {
        Text(
          """
          Without it, macOS asks for permission each time an agent reads your Desktop, Documents, \
          Downloads, an external disk or iCloud Drive. Turning it on takes effect the next time \
          Vibe Manager is opened.
          """
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Button("Open System Settings") {
          permissions.openSystemSettings()
        }
      }
    }
  }

  private var label: String {
    switch permissions.status {
    case .granted: return "Granted"
    case .notGranted: return "Not granted"
    case nil: return "Checking…"
    }
  }

  private var symbolName: String {
    switch permissions.status {
    case .granted: return "checkmark.circle"
    case .notGranted: return "exclamationmark.circle"
    case nil: return "clock"
    }
  }
}

private struct SessionCloseRow: View {
  @Bindable var model: AppModel

  var body: some View {
    Toggle(
      "Ask before closing a session whose agent is running",
      isOn: $model.confirmsStoppingRunningAgent
    )
  }
}
