import SwiftUI
import VibeApplication

/// The application's settings.
///
/// The first line is the permanent way back to Full Disk Access. The step at launch is asked once
/// and never again, so refusing it must not be a door that closes: this is where the user finds
/// the question again, on their own terms. The second is where worktrees go.
public struct SettingsView: View {
  private let permissions: PermissionsModel?
  private let worktreeRoot: WorktreeRootSettings?

  public init(permissions: PermissionsModel? = nil, worktreeRoot: WorktreeRootSettings? = nil) {
    self.permissions = permissions
    self.worktreeRoot = worktreeRoot
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
      if let worktreeRoot {
        Section("Worktrees") {
          WorktreeRootRow(settings: worktreeRoot)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .task {
      await permissions?.recheck()
      await worktreeRoot?.load()
    }
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

private struct WorktreeRootRow: View {
  let settings: WorktreeRootSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Folder") {
        Text(settings.path.map(abbreviatedPath) ?? "…")
          .lineLimit(1)
          .truncationMode(.middle)
          .help(settings.path ?? "")
      }
      Text(
        """
        Each session's worktrees go in a folder of its own under this one — never inside a \
        repository, where they would show up in its status and in the agent's searches. Changing \
        it moves nothing that already exists.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Choose…") {
          guard let path = chooseFolder(startingAt: settings.path) else { return }
          Task { await settings.choose(path) }
        }
        if !settings.isDefault {
          Button("Use the Default") { Task { await settings.reset() } }
        }
      }
    }
  }
}
