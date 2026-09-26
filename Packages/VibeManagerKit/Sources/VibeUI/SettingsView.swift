import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication
import VibeBrowser
import VibeConversationUI
import VibeDomain

/// The application's settings, in tabs: General, Privacy, the prompt templates, the web view, the
/// activity and the conversation view.
///
/// Several lines are ways back to a question asked once. The Full Disk Access step at launch is
/// not asked again by the same identity, and neither is the close confirmation once "Don't ask
/// again" was ticked: refusing either must not be a door that closes, so this is where the user
/// finds the question again.
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
        if let permissions {
          PrivacySettingsView(permissions: permissions, sessionName: model.sessionName(for:))
            .tabItem {
              Label {
                Text("Privacy", bundle: .module, comment: "A tab of the Settings window.")
              } icon: {
                Image(systemName: "hand.raised")
              }
            }
            .tag(SettingsTab.privacy)
        }
        PromptTemplatesView(model: model.templates)
          .tabItem {
            Label {
              Text("Templates", bundle: .module, comment: "A tab of the Settings window.")
            } icon: {
              Image(systemName: "text.badge.plus")
            }
          }
          .tag(SettingsTab.templates)
        if let browser = model.browser {
          WebViewSettings(browser: browser)
            .tabItem {
              Label {
                Text("Web View", bundle: .module, comment: "A tab of the Settings window.")
              } icon: {
                Image(systemName: "globe")
              }
            }
            .tag(SettingsTab.webView)
        }
        if let journal = model.journal {
          ActivitySettings(journal: journal)
            .tabItem {
              Label {
                Text("Activity", bundle: .module, comment: "A tab of the Settings window.")
              } icon: {
                Image(systemName: "list.bullet.rectangle")
              }
            }
            .tag(SettingsTab.activity)
        }
        ConversationSettingsView(appearance: Bindable(model.conversations).appearance)
          .tabItem {
            Label {
              Text("Conversation", bundle: .module, comment: "A tab of the Settings window.")
            } icon: {
              Image(systemName: "bubble.left.and.text.bubble.right")
            }
          }
          .tag(SettingsTab.conversation)
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
      // In a tab of its own when the window has tabs (#76): it grew past what a line of General
      // can hold. Without the workspace, the window is this one form, and keeps it here.
      if model == nil {
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
    .task {
      guard model == nil else { return }
      await permissions?.recheck()
    }
  }
}

/// The tabs of the settings window.
public enum SettingsTab: String, Hashable, Sendable {
  case general
  /// Full Disk Access, and the processes it has to reach (#76).
  case privacy
  /// The prompt templates: a list, an editor and a preview, which need the room of a tab of their
  /// own rather than a section of a form.
  case templates
  /// The session's web view (#69): what agents may do there, and where links go.
  case webView
  /// What each session's journal does: the summary its agent writes (#36).
  case activity
  /// The conversation view of #38: its theme, its fonts, what it unfolds.
  case conversation
}

/// Full Disk Access, and whether it has reached the agents yet.
///
/// Asks a process born now each time the tab is opened: whoever opens it has usually just been to
/// System Settings, and this window — launched before — could only repeat what it got then.
struct PrivacySettingsView: View {
  let permissions: PermissionsModel
  let sessionName: (SessionID) -> String

  var body: some View {
    Form {
      Section {
        FullDiskAccessRow(permissions: permissions)
      } header: {
        Text("Full Disk Access", bundle: .module, comment: "A section of the Settings window.")
      }
      if let report = permissions.report, !report.isConsistent {
        Section {
          ProcessAccessRows(report: report)
        } header: {
          Text("Process by Process", bundle: .module, comment: "A section of the Settings window.")
        } footer: {
          Text(
            """
            macOS gives each process the access it had when it started. Agents run in a \
            background process of Vibe Manager, which keeps running while they work.
            """,
            bundle: .module
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      Section {
        SystemSettingsRow(permissions: permissions)
      } header: {
        Text("System Settings", bundle: .module, comment: "A section of the Settings window.")
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 500)
    .restartNowConfirmation(permissions: permissions, origin: .settings, sessionName: sessionName)
    .task { await permissions.recheck() }
  }
}

/// The access as the agents get it, and what to do about it.
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
        .foregroundStyle(permissions.situation == .granted ? .secondary : .primary)
      } label: {
        Text("Full Disk Access", bundle: .module)
      }

      switch permissions.situation {
      case .notGranted:
        Text(
          """
          Without it, macOS asks for permission each time an agent reads your Desktop, Documents, \
          Downloads, an external disk or iCloud Drive.
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
      case .pendingRestart(let runner, let running):
        PendingRestartExplanation(runner: runner, runningAgents: running)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if runner == .host, running > 0 {
          RestartHostButtons(permissions: permissions, origin: .settings)
        }
      case .granted, .checking:
        EmptyView()
      }
    }
  }

  private var label: LocalizedStringResource {
    switch permissions.situation {
    case .granted:
      return LocalizedStringResource(
        "Granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .notGranted:
      return LocalizedStringResource(
        "Not granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .pendingRestart:
      return LocalizedStringResource(
        "Granted, not yet in effect", bundle: .module,
        comment: "The state of Full Disk Access: granted, but the agents do not have it yet.")
    case .checking:
      return LocalizedStringResource(
        "Checking…", bundle: .module, comment: "The state of Full Disk Access.")
    }
  }

  private var symbolName: String {
    switch permissions.situation {
    case .granted: return "checkmark.circle"
    case .notGranted: return "exclamationmark.circle"
    case .pendingRestart: return "arrow.clockwise.circle"
    case .checking: return "clock"
    }
  }
}

/// Why the access granted has not reached the agents, in one or two sentences.
struct PendingRestartExplanation: View {
  let runner: FullDiskAccessSituation.PendingRunner
  let runningAgents: Int

  var body: some View {
    switch runner {
    case .application:
      Text(
        "Agents run inside Vibe Manager for now. Quit and reopen Vibe Manager to give them the access.",
        bundle: .module)
    case .host:
      if runningAgents == 0 {
        Text(
          "The background process that runs agents is restarting to take the access.",
          bundle: .module)
      } else {
        Text(
          """
          The \(runningAgents) agents running now were started before the access was granted. \
          They get it once the background process that runs them restarts.
          """,
          bundle: .module,
          comment: "The number of agents running without Full Disk Access.")
      }
    }
  }
}

/// Restart the host when the last agent ends, or now — the one road that stops agents, and only
/// once they have been named.
struct RestartHostButtons: View {
  let permissions: PermissionsModel
  let origin: RestartNowRequest.Origin

  var body: some View {
    HStack {
      if permissions.isRestartArmed {
        Label {
          Text("Restarts when the last running agent ends.", bundle: .module)
        } icon: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .font(.callout)
        Button {
          Task { await permissions.cancelRestartWhenIdle() }
        } label: {
          Text("Don't Restart", bundle: .module)
        }
      } else {
        Button {
          Task { await permissions.restartWhenIdle() }
        } label: {
          Text("Restart When Idle", bundle: .module)
        }
      }
      Button {
        Task { await permissions.beginRestartNow(from: origin) }
      } label: {
        Text("Restart Now…", bundle: .module)
      }
      .disabled(!permissions.canRestartNow)
    }
  }
}

/// What each process got, when they disagree.
private struct ProcessAccessRows: View {
  let report: FullDiskAccessReport

  var body: some View {
    LabeledContent {
      Text(state(report.identity))
    } label: {
      Text("Vibe Manager", bundle: .module)
      Text("What a process of this copy gets when it starts now.", bundle: .module)
    }
    if report.runner.runner == .host {
      LabeledContent {
        Text(state(report.runner.hostStatus))
      } label: {
        Text("Background process that runs agents", bundle: .module)
        Text(
          "\(report.runner.runningAgents) agents running", bundle: .module,
          comment: "The number of agents running in the background process.")
      }
    }
    LabeledContent {
      Text(state(report.interface))
    } label: {
      Text("This window", bundle: .module)
      Text("Until Vibe Manager is next opened.", bundle: .module)
    }
  }

  private func state(_ status: FullDiskAccessStatus?) -> LocalizedStringResource {
    switch status {
    case .granted:
      return LocalizedStringResource(
        "Granted", bundle: .module, comment: "The state of Full Disk Access.")
    case .notGranted:
      return LocalizedStringResource(
        "Not granted", bundle: .module, comment: "The state of Full Disk Access.")
    case nil:
      return LocalizedStringResource(
        "Unknown", bundle: .module,
        comment: "The state of Full Disk Access of a process that cannot say.")
    }
  }
}

/// Where the switch is, and which of several identical entries is this copy.
private struct SystemSettingsRow: View {
  let permissions: PermissionsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        """
        Several “Vibe Manager” in the list? Each build signed differently is a separate entry. \
        Drag this copy into the list to add the right one.
        """,
        bundle: .module
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button {
          permissions.revealInFinder()
        } label: {
          Text("Show in Finder", bundle: .module)
        }
        Button {
          permissions.openSystemSettings()
        } label: {
          Text("Open System Settings", bundle: .module)
        }
      }
    }
  }
}

extension View {
  /// Asks before "Restart Now" stops the agents it names.
  func restartNowConfirmation(
    permissions: PermissionsModel, origin: RestartNowRequest.Origin,
    sessionName: @escaping (SessionID) -> String
  ) -> some View {
    modifier(
      RestartNowConfirmation(permissions: permissions, origin: origin, sessionName: sessionName))
  }

  /// The same, for a workspace that may have no permissions to speak of.
  @ViewBuilder
  func restartNowConfirmation(
    permissions: PermissionsModel?, origin: RestartNowRequest.Origin,
    sessionName: @escaping (SessionID) -> String
  ) -> some View {
    if let permissions {
      restartNowConfirmation(permissions: permissions, origin: origin, sessionName: sessionName)
    } else {
      self
    }
  }
}

/// Put only in the window that asked, with the sessions it named: the button carries them, so the
/// alert closing — which clears the request — cannot lose them on the way.
private struct RestartNowConfirmation: ViewModifier {
  let permissions: PermissionsModel
  let origin: RestartNowRequest.Origin
  let sessionName: (SessionID) -> String

  private var request: RestartNowRequest? {
    permissions.pendingRestartNow.flatMap { $0.origin == origin ? $0 : nil }
  }

  func body(content: Content) -> some View {
    content.alert(
      Text("Restart the running agents?", bundle: .module),
      isPresented: Binding(
        get: { request != nil },
        set: { if !$0, request != nil { permissions.cancelRestartNow() } }),
      presenting: request
    ) { request in
      Button(role: .destructive) {
        Task { await permissions.confirmRestartNow(request) }
      } label: {
        Text("Restart Now", bundle: .module)
      }
      Button(role: .cancel) {
        permissions.cancelRestartNow()
      } label: {
        Text("Cancel", bundle: .module)
      }
    } message: { request in
      Text(
        """
        \(request.sessions.map(sessionName).formatted(.list(type: .and))) will stop, then resume their \
        conversation with Full Disk Access. What an agent is doing right now is interrupted.
        """,
        bundle: .module,
        comment: "The names of the sessions whose agent is restarted, as a list.")
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

/// The settings of the sessions' journal (#36), in a tab of their own.
private struct ActivitySettings: View {
  let journal: SessionJournalModel

  var body: some View {
    Form {
      Section {
        SummaryRow(journal: journal)
      } header: {
        Text("Summary", bundle: .module, comment: "The heading of a session's summary.")
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 500)
  }
}

/// Whether each session's agent writes the summary of what it did (#36).
private struct SummaryRow: View {
  @Bindable var journal: SessionJournalModel

  var body: some View {
    Toggle(isOn: $journal.summariesEnabled) {
      Text("Summarize sessions automatically", bundle: .module)
      Text(
        """
        After each turn, the session's agent writes a short summary of what it did, with the same \
        account, the lightest model it offers and at most one summary every five minutes. The \
        tickets, requests, branches and worktrees used are listed either way.
        """,
        bundle: .module)
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

/// Settings › Web View (#69), a tab of its own. The preferences are read once and written as they
/// change: they live in the user defaults, which the view does not observe.
private struct WebViewSettings: View {
  let browser: BrowserWorkspace
  @State private var givesAgents = true
  @State private var showsOnAgentPage = true
  @State private var links: TerminalLinkDestination = .webView
  @State private var isConfirmingClear = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $givesAgents) {
          Text("Give agents the web view", bundle: .module)
          Text("From the next start of an agent.", bundle: .module)
        }
        .onChange(of: givesAgents) { _, value in browser.preferences.givesAgentsWebView = value }
        Toggle(isOn: $showsOnAgentPage) {
          Text("Show the web view when an agent opens a page", bundle: .module)
        }
        .onChange(of: showsOnAgentPage) { _, value in
          browser.preferences.showsWebViewWhenAgentOpensPage = value
        }
        Picker(selection: $links) {
          Text("In the web view", bundle: .module).tag(TerminalLinkDestination.webView)
          Text("In the default browser", bundle: .module)
            .tag(TerminalLinkDestination.defaultBrowser)
        } label: {
          Text("Open links ⌘-clicked in the terminal", bundle: .module)
        }
        .onChange(of: links) { _, value in browser.preferences.terminalLinks = value }
      }
      Section {
        if browser.grants.isEmpty {
          Text("None", bundle: .module, comment: "No site is always allowed.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(browser.grants.sorted(), id: \.self) { site in
            LabeledContent {
              Button {
                browser.revokeGrant(site)
              } label: {
                Text("Remove", bundle: .module)
              }
            } label: {
              Text(verbatim: site)
            }
          }
        }
      } header: {
        Text("Always allowed sites", bundle: .module)
      } footer: {
        Text(
          "Elsewhere than this Mac, an agent asks before clicking, typing or running JavaScript.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent {
          Button {
            isConfirmingClear = true
          } label: {
            Text("Clear…", bundle: .module, comment: "Clears the web view's browsing data.")
          }
        } label: {
          Text("Browsing data", bundle: .module)
          Text("Shared by every session, apart from Safari.", bundle: .module)
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 500)
    .onAppear {
      givesAgents = browser.preferences.givesAgentsWebView
      showsOnAgentPage = browser.preferences.showsWebViewWhenAgentOpensPage
      links = browser.preferences.terminalLinks
    }
    .confirmationDialog(
      Text("Clear the web view’s browsing data?", bundle: .module),
      isPresented: $isConfirmingClear
    ) {
      Button(role: .destructive) {
        Task { await browser.configuration.clearBrowsingData() }
      } label: {
        Text("Clear", bundle: .module)
      }
    } message: {
      Text(
        "You will be signed out of every site in every session’s web view.", bundle: .module)
    }
  }
}
