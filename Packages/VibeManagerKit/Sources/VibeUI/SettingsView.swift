import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// The application's settings, in tabs: General, and the prompt templates.
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
    if let model {
      TabView(selection: Bindable(model).settingsTab) {
        general
          .tabItem {
            Label {
              Text("General", bundle: .module, comment: "A tab of the Settings window.")
            } icon: {
              Image(systemName: "gearshape")
            }
          }
          .tag(SettingsTab.general)
        PromptTemplatesView(model: model.templates)
          .tabItem {
            Label {
              Text("Templates", bundle: .module, comment: "A tab of the Settings window.")
            } icon: {
              Image(systemName: "text.badge.plus")
            }
          }
          .tag(SettingsTab.templates)
      }
    } else {
      general
    }
  }

  private var general: some View {
    Form {
      if let model {
        Section {
          SessionCloseRow(model: model)
          QuitBehaviorRow(model: model)
        } header: {
          Text("Sessions", bundle: .module, comment: "A section of the Settings window.")
        }
        Section {
          EditorRow(model: model)
        } header: {
          Text("Git", bundle: .module, comment: "A section of the Settings window.")
        }
        if !model.hookTrustingAgents.isEmpty {
          Section {
            ForEach(model.hookTrustingAgents, id: \.id) { agent in
              AgentActivityRow(model: model, agent: agent)
            }
          } header: {
            Text("Agent Activity", bundle: .module, comment: "A section of the Settings window.")
          }
        }
        if let usage = model.usage {
          Section {
            UsageSettingsRow(usage: usage)
          } header: {
            Text("Usage", bundle: .module, comment: "A section of the Settings window.")
          }
        }
      }
      Section {
        if let permissions {
          FullDiskAccessRow(permissions: permissions)
        } else {
          Text("File access cannot be read in this window.", bundle: .module)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Privacy", bundle: .module, comment: "A section of the Settings window.")
      }
      if let model, model.canExportDiagnostics {
        Section {
          LabeledContent {
            Button {
              model.beginDiagnosticsExport()
            } label: {
              Text("Export Diagnostics…", bundle: .module)
            }
          } label: {
            Text("Diagnostics", bundle: .module)
            Text(
              """
              A local log of what the application did, never of what you typed, kept for two \
              weeks. Exported only when you save it yourself.
              """,
              bundle: .module
            )
          }
        } header: {
          Text("Diagnostics", bundle: .module)
        }
      }
    }
    .formStyle(.grouped)
    // As tall as what it holds: the settings window takes each tab's size, and a form that
    // scrolls gives none, which left General in a window as tall as Templates.
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 500)
    .task { await permissions?.recheck() }
  }
}

/// The tabs of the settings window.
public enum SettingsTab: String, Hashable, Sendable {
  case general
  /// The prompt templates: a list, an editor and a preview, which need the room of a tab of their
  /// own rather than a section of a form.
  case templates
}

private struct FullDiskAccessRow: View {
  let permissions: PermissionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        Label {
          Text(label)
        } icon: {
          Image(systemName: symbolName)
        }
        .foregroundStyle(permissions.isGranted ? .secondary : .primary)
      } label: {
        Text("Full Disk Access", bundle: .module)
      }

      if permissions.status == .notGranted {
        Text(
          """
          Without it, macOS asks for permission each time an agent reads your Desktop, Documents, \
          Downloads, an external disk or iCloud Drive. Turning it on takes effect the next time \
          Vibe Manager is opened.
          """,
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Button {
          permissions.openSystemSettings()
        } label: {
          Text("Open System Settings", bundle: .module)
        }
      }
    }
  }

  private var label: LocalizedStringResource {
    switch permissions.status {
    case .granted:
      return LocalizedStringResource(
        "Granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .notGranted:
      return LocalizedStringResource(
        "Not granted", bundle: .module, comment: "The state of Full Disk Access.")
    case nil:
      return LocalizedStringResource(
        "Checking…", bundle: .module, comment: "The state of Full Disk Access.")
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

/// Whether an agent whose CLI approves its hooks reports its activity (#45). Turned back on, the
/// next launch of that agent asks again.
private struct AgentActivityRow: View {
  let model: AppModel
  let agent: AgentDescriptor

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { model.reportsActivity[agent.id] ?? true },
        set: { model.setReportsActivity($0, for: agent.id) })
    ) {
      Text(
        "Track \(agent.displayName) activity", bundle: .module,
        comment: "A setting; the argument is the agent's name.")
      Text(
        "Shows in the sidebar when it works, asks a question or has finished. Needs hooks \(agent.displayName) asks you to approve once.",
        bundle: .module,
        comment:
          "Under the setting that tracks an agent's activity; the argument is the agent's name.")
    }
  }
}

private struct SessionCloseRow: View {
  @Bindable var model: AppModel

  var body: some View {
    Toggle(isOn: $model.confirmsStoppingRunningAgent) {
      Text("Ask before closing a session whose agent is running", bundle: .module)
    }
  }
}

/// The question asked when quitting with agents running, and the way back to it once
/// "Don't ask again" was ticked.
private struct QuitBehaviorRow: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(selection: $model.quitBehavior) {
        Text("Ask", bundle: .module, comment: "What to do when quitting with agents running.")
          .tag(QuitBehavior.ask)
        Text(
          "Keep them running", bundle: .module,
          comment: "What to do when quitting with agents running."
        )
        .tag(QuitBehavior.keepRunning)
        Text("Stop them", bundle: .module, comment: "What to do when quitting with agents running.")
          .tag(QuitBehavior.stopAll)
      } label: {
        Text("When quitting with agents running", bundle: .module)
      }
      Text(
        """
        Agents kept running go on working in the background, and are back on screen as they are \
        the next time Vibe Manager is opened. A restart of the Mac stops them.
        """,
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
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
      Picker(selection: selection) {
        Text("Finder (reveal only)", bundle: .module).tag(Choice.revealOnly)
        Text("Default Application", bundle: .module).tag(Choice.defaultApplication)
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
        Text("Other…", bundle: .module, comment: "Picks another application to open files with.")
          .tag(Choice.other)
      } label: {
        Text("Open changed files with", bundle: .module)
      }
      .id(pickerIdentity)
      if case .application = model.fileEditor, let editor = model.fileEditor,
        model.gitInspector.name(of: editor) == nil
      {
        Text(
          "This editor is no longer installed: files are revealed in the Finder instead.",
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Text("Double-click a file in the Git list, or press Return, to open it.", bundle: .module)
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
    panel.prompt = String(
      localized: "Choose", bundle: .module,
      comment: "The button of the panel that picks an application to open files with.")
    guard panel.runModal() == .OK, let url = panel.url,
      let identifier = Bundle(url: url)?.bundleIdentifier
    else {
      pickerIdentity += 1
      return
    }
    model.fileEditor = .application(bundleIdentifier: identifier)
  }
}

/// Turning usage tracking off, and forgetting what it recorded.
///
/// Off, nothing is written and no transcript is read for usage; what was recorded stays visible.
/// Clearing deletes what the application recorded, never the agents' own transcripts.
private struct UsageSettingsRow: View {
  let usage: UsageModel
  @State private var isConfirmingClear = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { usage.isTrackingEnabled },
          set: { enabled in Task { await usage.setTracking(enabled) } }
        )
      ) {
        Text("Track agent usage", bundle: .module)
      }
      Text(
        """
        Running time, runs and the tokens your agents' transcripts report, kept on this Mac only. \
        Nothing is sent anywhere, and what the agents were asked or answered is never read.
        """,
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        isConfirmingClear = true
      } label: {
        Text("Clear Usage Data…", bundle: .module)
      }
      .confirmationDialog(
        Text("Clear usage data?", bundle: .module), isPresented: $isConfirmingClear
      ) {
        Button(role: .destructive) {
          Task { await usage.clear() }
        } label: {
          Text("Clear Usage Data", bundle: .module)
        }
      } message: {
        Text(
          """
          Running times, runs and token totals recorded on this Mac will be deleted. Your \
          agents' own transcripts are not touched.
          """,
          bundle: .module
        )
      }
    }
  }
}
