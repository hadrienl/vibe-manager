import SwiftUI
import VibeApplication

/// The application's settings, which for now are one line — and that line matters.
///
/// It is the permanent way back to Full Disk Access. The step at launch is asked once and never
/// again, so refusing it must not be a door that closes: this is where the user finds the question
/// again, on their own terms.
public struct SettingsView: View {
  private let permissions: PermissionsModel?

  public init(permissions: PermissionsModel? = nil) {
    self.permissions = permissions
  }

  public var body: some View {
    Form {
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
          Task { await permissions.openSystemSettings() }
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
