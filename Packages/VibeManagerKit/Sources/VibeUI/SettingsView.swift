import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
        Section("Git") {
          EditorRow(model: model)
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

/// Where a changed file of the inspector opens. Without a choice it is only revealed: nothing is
/// opened in an application the user did not pick.
private struct EditorRow: View {
  @Bindable var model: AppModel
  /// Renewed when "Other…" is cancelled: the setting did not change, so nothing else would bring
  /// the popup back from "Other…" to the choice that holds.
  @State private var pickerIdentity = 0

  private enum Choice: Hashable {
    case revealOnly
    case defaultApplication
    case application(String)
    case other
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Open changed files with", selection: selection) {
        Text("Finder (reveal only)").tag(Choice.revealOnly)
        Text("Default Application").tag(Choice.defaultApplication)
        let editors = model.gitInspector.installedEditors()
        if !editors.isEmpty || chosenElsewhere != nil {
          Divider()
        }
        ForEach(editors, id: \.bundleIdentifier) { editor in
          Text(editor.name).tag(Choice.application(editor.bundleIdentifier))
        }
        if let chosenElsewhere {
          Text(chosenElsewhere.name).tag(Choice.application(chosenElsewhere.identifier))
        }
        Divider()
        Text("Other…").tag(Choice.other)
      }
      .id(pickerIdentity)
      if case .application = model.fileEditor, let editor = model.fileEditor,
        model.gitInspector.name(of: editor) == nil
      {
        Text("This editor is no longer installed: files are revealed in the Finder instead.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Double-click a file in the Git list, or press Return, to open it.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The chosen application when the installed editors do not list it: picked with "Other…", or
  /// a known editor uninstalled since. Without it the picker would show no choice at all.
  private var chosenElsewhere: (identifier: String, name: String)? {
    guard case .application(let identifier) = model.fileEditor,
      !model.gitInspector.installedEditors().contains(where: { $0.bundleIdentifier == identifier })
    else { return nil }
    return (
      identifier,
      model.gitInspector.name(of: .application(bundleIdentifier: identifier)) ?? identifier
    )
  }

  private var selection: Binding<Choice> {
    Binding(
      get: {
        switch model.fileEditor {
        case nil: return .revealOnly
        case .defaultApplication: return .defaultApplication
        case .application(let identifier): return .application(identifier)
        }
      },
      set: { choice in
        switch choice {
        case .revealOnly: model.fileEditor = nil
        case .defaultApplication: model.fileEditor = .defaultApplication
        case .application(let identifier):
          model.fileEditor = .application(bundleIdentifier: identifier)
        case .other: chooseApplication()
        }
      }
    )
  }

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url,
      let identifier = Bundle(url: url)?.bundleIdentifier
    else {
      pickerIdentity += 1
      return
    }
    model.fileEditor = .application(bundleIdentifier: identifier)
  }
}
