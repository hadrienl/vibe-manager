import AppKit
import SwiftUI
import VibeApplication
import VibeBrowser
import VibeComposition
import VibeDomain
import VibePersistence
import VibeTerminal
import VibeUI
import VibeUpdates

/// The one binary is seven programs. Given `--terminal-host`, it is the terminal host (ADR 0017);
/// given `--browser-bridge` or `--browser-cli`, the web view's bridge an agent starts or the `vibe`
/// command (ADR 0023); given `--probe-full-disk-access`, it says whether a process born now has Full
/// Disk Access, and exits (#76); given `--terminal-exec`, it takes its terminal as its controlling
/// one and becomes a side terminal's shell (#43); given `--endpoint-gateway`, it is the gateway
/// between an agent and a model endpoint (#107). Those never return: no `NSApplication` is created,
/// so they have no Dock icon, no menu bar and no window. Being the same signed binary is the point:
/// TCC and the peer checks all see Vibe Manager.
@main
enum Entry {
  static func main() {
    // First: the shell it becomes should inherit as little of this process as possible.
    ControllingTerminal.runIfRequested()
    // The application and the terminal host both start side terminals through this very binary.
    ControllingTerminal.useTrampoline(at: Bundle.main.executablePath)
    FullDiskAccessProbeCommand.runIfRequested(probe: TCCFullDiskAccessProbe())
    BrowserBridge.runIfRequested()
    TerminalHost.runIfRequested(
      diagnostics: { directory in
        Diagnostics.standard(location: DiagnosticsLocation(directory: directory), origin: .host).0
      },
      // What every agent it runs inherits, and what the application asks it.
      fullDiskAccess: TCCFullDiskAccessProbe())
    // The gateway between Claude Code or Codex and a model endpoint (#107).
    EndpointGatewayCommand.runIfRequested()
    VibeManagerApp.main()
  }
}

struct VibeManagerApp: App {
  private static let troubleshooting = URL(
    string: "https://github.com/hadrienl/vibe-manager/blob/main/docs/operations.md")
  /// Where help lives until there is documentation: the questions already asked, and a place to
  /// ask a new one.
  private static let issues = URL(string: "https://github.com/hadrienl/vibe-manager/issues")
  private static let newIssue = URL(string: "https://github.com/hadrienl/vibe-manager/issues/new")

  @State private var environment = AppEnvironment()
  @State private var windowFocus = WindowFocus()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// The workspace's window, opened again by ⌘N once closed (#247).
  static let workspaceWindowID = "workspace"

  /// How long a help tag waits before showing, in milliseconds. The system's own delay is long
  /// enough that the small buttons of the sidebar's foot read as unlabelled. Registered as a
  /// default, so a value the user set with `defaults write` still wins.
  private static let toolTipDelay = 400

  init() {
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": Self.toolTipDelay])
  }

  var body: some Scene {
    WindowGroup(id: Self.workspaceWindowID) {
      RootView(model: environment.appModel)
        .onAppear {
          appDelegate.environment = environment
          // Notifications need the application's bundle: the notifier is made here, not in the
          // package, whose tests have none (#40).
          if environment.appModel.requestNotifier == nil {
            environment.appModel.requestNotifier = SystemRequestNotifier(
              model: environment.appModel)
          }
          // The requests above the other applications (#41): a window of its own, shown only
          // when the option is on and Vibe Manager is not in front.
          if appDelegate.floatingPanel == nil {
            appDelegate.floatingPanel = FloatingRequestPanelController(model: environment.appModel)
          }
          // The updater replaces the bundle this process runs from (#92): made here, not in the
          // package, whose tests have no bundle of their own to replace.
          if environment.appModel.updates == nil {
            environment.appModel.updates = appDelegate.startUpdates(in: environment)
          }
        }
        .background(WorkspaceWindowReader(focus: windowFocus))
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Vibe Manager") {
          AboutPanel.show()
        }
      }

      CommandGroup(after: .appInfo) {
        UpdateCommands(model: environment.appModel)
      }

      CommandGroup(replacing: .newItem) {
        NewSessionButton(model: environment.appModel, focus: windowFocus)

        TemplateCommands(model: environment.appModel)
      }

      // SwiftUI's own Close sits here on ⌘W: over the workspace, ⌘W closes what holds the
      // keyboard inside the session — a tab of the web view, a side terminal — and the session
      // itself is ⇧⌘W, in the Session menu (#165). The window keeps its item without a key: it
      // is the only one, and its red button is still there.
      CommandGroup(replacing: .saveItem) {
        InnerCloseButton(model: environment.appModel, focus: windowFocus)

        Button("Close Window") {
          windowFocus.closeKeyWindow()
        }
        .disabled(windowFocus.front == .none || windowFocus.front == .sheet)
      }

      // Open Quickly (#37), where Print was: there is nothing to print in the application. From
      // Settings or Usage it brings the workspace forward first; over a sheet it does nothing.
      CommandGroup(replacing: .printItem) {
        Button("Open Quickly…") {
          if windowFocus.front != .workspace { windowFocus.showWorkspace() }
          environment.appModel.presentQuickOpen()
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(
          windowFocus.front == .sheet || !windowFocus.hasWorkspace
            || !environment.appModel.isLoaded)
      }

      // In the menus rather than bound to the views: a shortcut that only works while a
      // particular view holds focus is a shortcut nobody can rely on, and the menu is also
      // where VoiceOver and the keyboard-only user find these actions at all.
      CommandGroup(after: .sidebar) {
        Button(
          environment.appModel.layout.columns.isInspectorVisible
            ? String(localized: "Hide Context", comment: "Hides the inspector of the window.")
            : String(localized: "Show Context", comment: "Shows the inspector of the window.")
        ) {
          environment.appModel.layout.toggleInspector()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])

        // The sections of the context column back in their first order, sizes and folds (#66).
        Button("Reset Column Layout") {
          environment.appModel.layout.resetInspectorSections()
        }
        .disabled(environment.appModel.layout.isInspectorArrangementDefault)

        Button(
          environment.appModel.isWebViewOpen
            ? String(localized: "Hide Web View", comment: "Hides the session's web view.")
            : String(localized: "Show Web View", comment: "Shows the session's web view.")
        ) {
          environment.appModel.toggleWebView()
        }
        .keyboardShortcut("b", modifiers: [.command, .option])
        .disabled(!environment.appModel.isWebViewAvailable)

        // Without it the terminal keeps the keyboard, and the notes can only be reached with the
        // pointer. Escape in the notes hands the keyboard back.
        Button("Edit Notes") {
          environment.appModel.focusNotes()
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(!environment.appModel.isSessionOnScreen)

        // The same session, as a conversation or as its raw terminal (#38).
        Button(
          environment.appModel.selectedSession.map { environment.appModel.presentation(of: $0) }
            == .conversation
            ? String(localized: "Show Terminal", comment: "Shows the raw terminal of the session.")
            : String(
              localized: "Show Conversation", comment: "Shows the session as a conversation.")
        ) {
          environment.appModel.togglePresentation()
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(!environment.appModel.canTogglePresentation)

        // The session's drawer of side terminals (#43). Hiding it stops nothing.
        Button(
          environment.appModel.isDrawerShown
            ? String(
              localized: "Hide Terminals",
              comment: "Hides the drawer of the session's side terminals.")
            : String(
              localized: "Show Terminals",
              comment: "Shows the drawer of the session's side terminals.")
        ) {
          environment.appModel.toggleDrawer()
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(!environment.appModel.canToggleDrawer)

        // ⌘T follows the keyboard, like ⌘W (#165): in the web view a new tab, as in a browser
        // (#247); anywhere else a new side terminal. Over another window, never a web tab.
        if windowFocus.front == .workspace, environment.appModel.closesWebTab {
          Button("New Tab") {
            environment.appModel.newWebTab()
          }
          .keyboardShortcut("t", modifiers: .command)
        } else {
          Button("New Terminal") {
            environment.appModel.newDrawerTerminal()
          }
          .keyboardShortcut("t", modifiers: .command)
          .disabled(!environment.appModel.canAddDrawerTerminal)
        }

        Divider()

        Button("Next Session") {
          environment.appModel.selectNext()
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])

        Button("Previous Session") {
          environment.appModel.selectPrevious()
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])

        // The order arranged by hand (#44), as the prompt templates are: only in the Manual sort,
        // and never out of the session's group. Over Settings, the same keys move a template.
        Button("Move Up") {
          Task { await environment.appModel.moveSelection(by: -1) }
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .control])
        .disabled(
          windowFocus.front != .workspace || !environment.appModel.canMoveSelection(by: -1))

        Button("Move Down") {
          Task { await environment.appModel.moveSelection(by: 1) }
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .control])
        .disabled(
          windowFocus.front != .workspace || !environment.appModel.canMoveSelection(by: 1))

        SessionPositionCommands(model: environment.appModel)

        Divider()

        GroupCommands(model: environment.appModel)

        Divider()

        // The columns of the sidebar (#80), in their order, stopping at both ends. ⌥⌘ walks, on
        // both axes — ↑↓ the sessions, ←→ the columns — and ⌃⌘ changes, ↑↓ the order and ←→ the
        // status (#240).
        Button("Next Column") {
          environment.appModel.showNextColumn()
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

        Button("Previous Column") {
          environment.appModel.showPreviousColumn()
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

        Divider()

        // Between the three zones of the window, from the keyboard alone. An agent in the
        // terminal loses these three combinations, which full-screen programs rarely use.
        Button("Focus Sidebar") {
          environment.appModel.focusSidebar()
        }
        .keyboardShortcut("1", modifiers: [.command, .option])

        // The quiet way in to the archive, from the keyboard (#44).
        Button(
          String(
            localized: "Show Archived Sessions (\(environment.appModel.archivedSessions.count))",
            comment: "Opens the list of the archived sessions; how many there are.")
        ) {
          environment.appModel.showArchivedSessions()
        }
        .keyboardShortcut("a", modifiers: [.command, .option])
        .disabled(!environment.appModel.isLoaded)

        // The session in the form it is shown in: its terminal, or its composer (#105).
        Button("Focus Session") {
          environment.appModel.focusSession()
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(!environment.appModel.isSessionOnScreen)

        Button("Focus Context") {
          environment.appModel.focusInspector()
        }
        .keyboardShortcut("3", modifiers: [.command, .option])
        .disabled(!environment.appModel.isSessionOnScreen)

        Button("Focus Web View") {
          environment.appModel.focusWebView()
        }
        .keyboardShortcut("4", modifiers: [.command, .option])
        .disabled(!environment.appModel.isWebViewAvailable)

        Button("Focus Side Terminals") {
          environment.appModel.focusDrawer()
        }
        .keyboardShortcut("5", modifiers: [.command, .option])
        .disabled(!environment.appModel.canToggleDrawer)

        // The requests of the sessions in the background (#40).
        Button("Focus Pending Requests") {
          environment.appModel.focusRequestPalette()
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(environment.appModel.pendingRequestCount == 0)

        // What the terminal said last, read by VoiceOver on demand rather than as it arrives.
        Button("Read Last Output") {
          Task { await environment.appModel.readLastOutput() }
        }
        .keyboardShortcut("o", modifiers: [.command, .option, .control])
      }

      SessionHistoryCommands(model: environment.appModel, focus: windowFocus)

      WebCommands(model: environment.appModel)

      ConversationCopyCommands()

      // Replacing the system's item, which only said that no help was available; the search field
      // stays.
      CommandGroup(replacing: .help) {
        if let issues = Self.issues {
          Link("Vibe Manager Help", destination: issues)
            .keyboardShortcut("?", modifiers: .command)
        }
        if let newIssue = Self.newIssue {
          Link("Report an Issue…", destination: newIssue)
        }
        Divider()
        // Known limits, and how to recover from each thing that can go wrong.
        if let troubleshooting = Self.troubleshooting {
          Link("Troubleshooting", destination: troubleshooting)
        }
        // Nothing leaves the Mac from here: the sheet shows the whole file, and the user saves it.
        Button("Export Diagnostics…") {
          environment.appModel.beginDiagnosticsExport()
        }
        .disabled(!environment.appModel.canExportDiagnostics)
      }
    }

    Settings {
      SettingsView(permissions: environment.permissions, model: environment.appModel)
    }
    // The user's to size, down to what a page needs: a page that needs more widens it (#313).
    .windowResizability(.contentMinSize)
    .defaultSize(width: 835, height: 700)
    // A title and the way back on one line, as System Settings: the preferences style, made for
    // tabs, centred the back button on a row of its own.
    .windowToolbarStyle(.unified)

    // One window, reopened rather than duplicated. SwiftUI lists it in the Window menu itself,
    // so the shortcut goes on the scene rather than on a second menu item.
    Window("Usage", id: "usage") {
      UsageWindow(model: environment.appModel)
    }
    .defaultSize(width: 820, height: 560)
    .keyboardShortcut("u", modifiers: [.command, .option])
  }
}

/// Starting a session from a template, and managing them.
///
/// ⇧⌘N opens the sheet on the first template, its fields ready to type in; the picker at the top
/// of the sheet changes it. The submenu goes straight to any of them.
private struct TemplateCommands: View {
  let model: AppModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("New Session from Template") {
      model.beginNewSession(template: model.templates.all.first?.id)
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])
    .disabled(!model.canCreateSession || model.templates.all.isEmpty)

    Menu("New Session from") {
      ForEach(model.templates.all) { template in
        Button(template.trimmedName) {
          model.beginNewSession(template: template.id)
        }
      }
    }
    .disabled(!model.canCreateSession || model.templates.all.isEmpty)

    Divider()

    Button("Manage Prompt Templates…") {
      model.settingsPage = .templates
      openSettings()
    }
  }
}

/// The standard About panel, with the website and the source under the version.
private enum AboutPanel {
  static let website = URL(string: "https://hadrienl.github.io/vibe-manager/")
  static let source = URL(string: "https://github.com/hadrienl/vibe-manager")

  @MainActor
  static func show() {
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate()
  }

  /// One centred line per link, in the panel's small system font.
  static var credits: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph,
    ]
    let links: [(String, URL?)] = [
      (String(localized: "Website"), website),
      (String(localized: "Source code on GitHub"), source),
    ]
    let credits = NSMutableAttributedString()
    for (title, url) in links {
      guard let url else { continue }
      if credits.length > 0 {
        credits.append(NSAttributedString(string: "\n", attributes: base))
      }
      var attributes = base
      attributes[.link] = url
      credits.append(NSAttributedString(string: title, attributes: attributes))
    }
    return credits
  }
}

/// Vibe Manager → Check for Updates… (#92). A copy that does not update itself still has the item:
/// it opens the Updates tab, which says why.
private struct UpdateCommands: View {
  let model: AppModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if let updates = model.updates {
      if let ready = updates.readyToInstall, updates.canOfferReadyUpdate {
        // Set aside by Later: installed when the application quits, or now from here.
        Button("Install Vibe Manager \(ready.version) and Relaunch…") {
          updates.offerReadyUpdate()
        }
      } else if !updates.isAvailable {
        Button("Check for Updates…") {
          model.settingsPage = .updates
          openSettings()
        }
      } else if let waiting = updates.waitingVersion {
        Button("Version \(waiting) Is Available…") {
          updates.checkNow()
        }
        .disabled(!updates.canCheck)
      } else {
        Button("Check for Updates…") {
          updates.checkNow()
        }
        .disabled(!updates.canCheck)
      }
    }
  }
}

/// ⌘1…⌘9, one menu item per position rather than one per session.
///
/// The items are fixed and only their labels follow the list: a menu that SwiftUI has not
/// rebuilt since a session was created or renamed then shows a stale name, where a menu built
/// from the sessions themselves would run the wrong one. `select(position:)` reads the list when
/// it is pressed, and does nothing when nobody is listed at that position.
private struct SessionPositionCommands: View {
  let model: AppModel

  var body: some View {
    ForEach(1...AppModel.shortcutPositionLimit, id: \.self) { position in
      Button(label(for: position)) {
        model.select(position: position)
      }
      .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
      .disabled(model.displayedSessions.count < position)
    }
  }

  /// The rows as the sidebar draws them, so the menu names the session the shortcut selects.
  private func label(for position: Int) -> String {
    let index = position - 1
    let displayed = model.displayedSessions
    guard displayed.indices.contains(index) else {
      return String(
        localized: "Session \(position)",
        comment: "A menu item for the session at this position in the list, when there is none.")
    }
    return displayed[index].name
  }
}

/// The sidebar by working folder (#27): the mode, and folding from the keyboard. ⌃⌥⌘← and ⌃⌥⌘→
/// fold and unfold the group of the selected session.
private struct GroupCommands: View {
  let model: AppModel

  var body: some View {
    Toggle(
      "Group Sessions by Folder",
      isOn: Binding(
        get: { model.sidebarMode == .byFolder },
        set: { model.setSidebarMode($0 ? .byFolder : .flat) })
    )
    .keyboardShortcut("g", modifiers: [.command, .control])

    Button("Collapse Group") {
      model.collapseSelectedGroup()
    }
    .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .control])
    .disabled(model.selectedGroup == nil || !model.canFold)

    Button("Expand Group") {
      model.expandSelectedGroup()
    }
    .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .control])
    .disabled(model.selectedGroup == nil || !model.canFold)

    Button("Collapse All Groups") {
      model.setAllGroupsExpanded(false)
    }
    .disabled(model.groups.isEmpty || !model.canFold)

    Button("Expand All Groups") {
      model.setAllGroupsExpanded(true)
    }
    .disabled(model.groups.isEmpty || !model.canFold)

    // A whole group, in the order arranged by hand (#44). No shortcut: ⌃⌘↑/↓ move the session.
    Button("Move Group Up") {
      Task { await model.moveSelectedGroup(by: -1) }
    }
    .disabled(!model.canMoveSelectedGroup(by: -1))

    Button("Move Group Down") {
      Task { await model.moveSelectedGroup(by: 1) }
    }
    .disabled(!model.canMoveSelectedGroup(by: 1))
  }
}

/// Restarting, closing, archiving and unarchiving the selected session, in their own menu.
///
/// Close Session is ⇧⌘W (#165), as closing the window is in Safari: the sessions are this window's
/// tabs' owners, and ⌘W closes what is inside one — a tab of its web view, a side terminal. ⌘W
/// used to close the session too, whenever the keyboard was in none of those: a key that closes a
/// tab or a whole session depending on where the keyboard happens to be is one that ends an
/// agent's work by accident. It still asks first when an agent is at work (#51).
///
/// Archive, ⌃⌘A, is the "done with this one" gesture (#115): it asks only when the agent or a
/// side terminal is at work, by the same rule and setting, and a burst of it empties a column.
///
/// Neither key falls back to closing the window: Close Window has no key, the window being the
/// only one. The other verbs keep ⌃⌘, so every one that moves a session through its life but the
/// most common shares one modifier.
private struct SessionHistoryCommands: Commands {
  let model: AppModel
  let focus: WindowFocus

  var body: some Commands {
    CommandMenu("Session") {
      // Over a new session's draft, the session underneath is not the one on screen: nothing here
      // acts on it, as nothing did under the sheet the draft replaced (#177). Attach Files… is
      // the exception, and joins the files to the draft's prompt.
      Group {
        sessionCommands
      }
      .disabled(model.isPresentingNewSession)

      // The keyboard's way to a drop (#42): chips in a conversation, paths in a terminal.
      Button("Attach Files…") {
        model.beginAttachingFiles()
      }
      .keyboardShortcut("o", modifiers: .command)
      .disabled(!model.canAttachFiles)

      Group {
        statusMenu

        Divider()

        closeButton
        archiveButtons
      }
      .disabled(model.isPresentingNewSession)
    }
  }

  @ViewBuilder
  private var sessionCommands: some View {
    // The label follows the session: one that was created and never ran is started, not
    // restarted, and the menu is where a keyboard-only user reads which of the two this is.
    // With several sessions selected in the sidebar, each command applies to all of them and
    // says how many it will act on (#77).
    if let plan = batchPlan(.restart) {
      Button(model.batchTitle(for: plan)) { request(plan) }
        .keyboardShortcut("r", modifiers: [.command, .control])
    } else {
      Button(
        model.selectedSession.map(model.restartTitle) ?? String(localized: "Restart Session")
      ) {
        guard let session = model.selectedSession else { return }
        Task { await model.restart(session.id) }
      }
      .keyboardShortcut("r", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canRestart) ?? false))
    }

    // Another agent or another model for the same work. Offered on a running session too: the
    // sheet says the agent will be stopped, and nothing is stopped before it is confirmed.
    Button("Switch Agent…") {
      guard let session = model.selectedSession else { return }
      model.beginAgentSwitch(session.id)
    }
    .keyboardShortcut("m", modifiers: [.command, .control])
    .disabled(
      model.hasMultipleSelection || !(model.selectedSession.map(model.canSwitchAgent) ?? false))

    // What the session is shown as (#183): on its row when the sidebar shows it, in the
    // inspector's header otherwise. The agent never hears of it.
    Button("Rename…") {
      guard let id = model.selectedSessionID else { return }
      model.beginRename(id)
    }
    .keyboardShortcut("e", modifiers: [.command, .control])
    .disabled(!canEditIdentity)

    Button("Change Icon…") {
      guard let id = model.selectedSessionID else { return }
      model.beginAppearanceEditing(id)
    }
    .keyboardShortcut("i", modifiers: [.command, .control])
    .disabled(!canEditIdentity)

    Button("Change Conversation Theme…") {
      guard let id = model.selectedSessionID else { return }
      model.beginThemeEditing(id)
    }
    .disabled(!canEditIdentity)
  }

  /// One session on screen, in the workspace: never several at once (#77), never under a sheet.
  private var canEditIdentity: Bool {
    focus.front == .workspace && !model.hasMultipleSelection
      && model.canEditIdentity(of: model.selectedSessionID)
  }

  @ViewBuilder
  private var statusMenu: some View {
    Divider()

    // The swipe's keyboard equivalent (#80), on ⌃⌘ like every arrow that changes a session
    // (#240): ⌘Z takes the move back, and only a move that would restart an agent asks first.
    Menu("Status") {
      if model.hasMultipleSelection {
        ForEach(SessionTaskStatus.columns, id: \.self) { status in
          let plan = model.batchPlan(.move(to: status), for: model.commandTargets)
          Button {
            request(plan)
          } label: {
            // The column the selection is already in reads as itself, and stays unavailable.
            plan.isEmpty ? Text(status.label) : Text(verbatim: model.batchTitle(for: plan))
          }
          .disabled(plan.isEmpty)
        }
      } else {
        statusToggles
      }
      Divider()
      Button("Move to Next Status") {
        if let plan = model.batchMovePlan(forward: true), model.hasMultipleSelection {
          request(plan)
          return
        }
        guard let session = model.selectedSession else { return }
        Task { await model.moveTaskStatus(of: session.id, forward: true) }
      }
      .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
      Button("Move to Previous Status") {
        if let plan = model.batchMovePlan(forward: false), model.hasMultipleSelection {
          request(plan)
          return
        }
        guard let session = model.selectedSession else { return }
        Task { await model.moveTaskStatus(of: session.id, forward: false) }
      }
      .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
    }
    .disabled(model.selectedSession.map { $0.taskStatus == .archived } ?? true)
  }

  @ViewBuilder
  private var statusToggles: some View {
    ForEach(SessionTaskStatus.columns, id: \.self) { status in
      Toggle(
        isOn: Binding(
          get: { model.selectedSession?.taskStatus == status },
          set: { isOn in
            guard isOn, let session = model.selectedSession else { return }
            Task { await model.setTaskStatus(status, for: session.id) }
          }
        )
      ) {
        Text(status.label)
      }
    }
  }

  @ViewBuilder
  private var closeButton: some View {
    // ⇧⌘W, wherever the keyboard is in the workspace: ⌘W is left to what holds it inside the
    // session (#165). With an agent at work, it asks first (#51).
    Button(closeTitle) {
      guard focus.front == .workspace else { return }
      if let plan = batchPlan(.close) {
        request(plan)
        return
      }
      guard let session = model.selectedSession else { return }
      Task { await model.requestClose(session.id) }
    }
    .keyboardShortcut("w", modifiers: [.command, .shift])
    .disabled(!isCloseEnabled)
  }

  @ViewBuilder
  private var archiveButtons: some View {
    if let plan = batchPlan(.archive) {
      Button(model.batchTitle(for: plan)) {
        guard !Self.isKeyRepeat else { return }
        request(plan)
      }
      .keyboardShortcut("a", modifiers: [.command, .control])
    } else {
      // A session where nothing runs is archived at once, and the name says so: the ellipsis only
      // when a question follows (#115).
      let asks = model.selectedSession.map(model.archiveAsks) ?? false
      Button(asks ? LocalizedStringKey("Archive…") : LocalizedStringKey("Archive")) {
        guard !Self.isKeyRepeat, let session = model.selectedSession else { return }
        Task { await model.requestArchive(session.id) }
      }
      .keyboardShortcut("a", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canArchive) ?? false))
    }

    if let plan = batchPlan(.unarchive) {
      Button(model.batchTitle(for: plan)) { request(plan) }
        .keyboardShortcut("a", modifiers: [.command, .control, .shift])
    } else {
      Button("Unarchive") {
        guard let session = model.selectedSession else { return }
        Task { await model.restore(session.id) }
      }
      .keyboardShortcut("a", modifiers: [.command, .control, .shift])
      .disabled(!(model.selectedSession.map(model.canRestore) ?? false))
    }
  }

  /// Whether the command comes from a key held down rather than pressed (#115). ⌃⌘A archives
  /// without asking: held, it would empty a whole column before the key is let go. Each press
  /// archives one session.
  private static var isKeyRepeat: Bool {
    NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
  }

  /// The selection's plan for a command, when several sessions are selected and it applies to at
  /// least one; `nil` otherwise. The session on screen is one of them and follows the same rules,
  /// so the item it falls back on is unavailable too, under its usual name.
  private func batchPlan(_ action: SessionBatchAction) -> SessionBatchPlan? {
    guard model.hasMultipleSelection else { return nil }
    let plan = model.batchPlan(action, for: model.commandTargets)
    return plan.isEmpty ? nil : plan
  }

  private func request(_ plan: SessionBatchPlan) {
    Task { await model.requestBatch(plan) }
  }

  private var closeTitle: String {
    if let plan = batchPlan(.close) { return model.batchTitle(for: plan) }
    return String(localized: "Close Session")
  }

  /// Over any other window, or under a sheet, the session behind is never closed.
  private var isCloseEnabled: Bool {
    guard focus.front == .workspace else { return false }
    if let plan = batchPlan(.close) { return !plan.isEmpty }
    return model.selectedSession.map(model.canClose) ?? false
  }
}

/// ⌘N, which also brings back the workspace window its red button closed (#247): without it, only
/// the Dock could.
private struct NewSessionButton: View {
  let model: AppModel
  let focus: WindowFocus
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("New Session") {
      if !focus.hasWorkspace { openWindow(id: VibeManagerApp.workspaceWindowID) }
      model.beginNewSession()
    }
    .keyboardShortcut("n", modifiers: .command)
    .disabled(!model.canCreateSession)
  }
}

/// ⌘W: the element inside the session that holds the keyboard, and the menu names it (#165) — the
/// web view's tab (ADR 0023), a side terminal (#43). With the keyboard anywhere else in the
/// workspace — the agent's terminal, the conversation, the sidebar — it is unavailable: it never
/// falls back on the session, which is ⇧⌘W, so a burst of ⌘W cannot close one by accident. Over
/// Settings or any other window, it closes that window.
private struct InnerCloseButton: View {
  let model: AppModel
  let focus: WindowFocus

  var body: some View {
    Button(title) {
      switch focus.front {
      case .workspace: model.closeInnerElement()
      case .other: focus.closeKeyWindow()
      case .sheet, .none: break
      }
    }
    .keyboardShortcut("w", modifiers: .command)
    .disabled(!isEnabled)
  }

  private var target: InnerCloseTarget? {
    focus.front == .workspace ? model.innerCloseTarget : nil
  }

  private var title: String {
    switch target {
    case .drawerTerminal:
      String(localized: "Close Terminal", comment: "Closes the side terminal in front.")
    case .webTab:
      String(localized: "Close Tab", comment: "Closes the web view's tab in front.")
    case nil:
      String(
        localized: "Close",
        comment: "⌘W with nothing inside the session to close, or over another window.")
    }
  }

  /// On the ticket's pinned tab, ⌘W stays available and beeps; nothing else is closed instead.
  private var isEnabled: Bool {
    switch focus.front {
    case .workspace: target != nil
    case .other: true
    case .sheet, .none: false
    }
  }
}

/// The web view's own menu (#69): moving through its tabs and pages from the keyboard.
private struct WebCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandMenu("Web") {
      // Without a key here: ⌘T is in the View menu, where it follows the keyboard (#247).
      Button("New Tab") {
        model.newWebTab()
      }
      .disabled(!model.isWebViewAvailable)

      Button("Open Location…") {
        model.focusAddressBar()
      }
      .keyboardShortcut("l", modifiers: .command)
      .disabled(!model.isWebViewAvailable)

      Button("Reload Page") {
        model.reloadWebTab()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.activeWebTab == nil)

      Button("Back") {
        model.goBackInWebTab()
      }
      .keyboardShortcut("[", modifiers: .command)
      .disabled(!(model.activeWebTab?.canGoBack ?? false))

      Button("Forward") {
        model.goForwardInWebTab()
      }
      .keyboardShortcut("]", modifiers: .command)
      .disabled(!(model.activeWebTab?.canGoForward ?? false))

      Divider()

      // With the keyboard in a side terminal, these move through the drawer's tabs instead (#43).
      Button("Show Next Tab") {
        if model.movesThroughDrawerTabs {
          model.selectNextDrawerTerminal()
        } else {
          model.selectNextWebTab()
        }
      }
      .keyboardShortcut(.tab, modifiers: .control)
      .disabled(!model.movesThroughDrawerTabs && (model.selectedBrowser?.allTabs.count ?? 0) < 2)

      Button("Show Previous Tab") {
        if model.movesThroughDrawerTabs {
          model.selectPreviousDrawerTerminal()
        } else {
          model.selectPreviousWebTab()
        }
      }
      .keyboardShortcut(.tab, modifiers: [.control, .shift])
      .disabled(!model.movesThroughDrawerTabs && (model.selectedBrowser?.allTabs.count ?? 0) < 2)

      Divider()

      Button("Open Page in Browser") {
        if let url = model.activeWebTab?.url { model.openOutside(url) }
      }
      .disabled(model.activeWebTab.map { !model.opensOutside($0.url) } ?? true)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var environment: AppEnvironment?
  /// The floating panel's window (#41), held for the life of the application.
  var floatingPanel: FloatingRequestPanelController?

  /// How long quitting may spend being tidy.
  ///
  /// The stop itself pays a three-second grace period per terminal, and this leaves room for the
  /// store writes around it. Past that the application stops waiting: an agent that ignores
  /// `SIGTERM`, and whose `SIGKILL` the kernel is slow to reap, was enough to make an application
  /// that would not quit — a worse failure than the orphan the wait was avoiding, and one the
  /// `atexit` guard of `TerminalProcessGroupGuard` catches anyway.
  private static let shutdownDeadline: Duration = .seconds(6)

  private var hasRepliedToTermination = false
  /// The updater (#92), held for the life of the application: Sparkle keeps only a weak reference
  /// to its delegate.
  private var updater: SparkleSoftwareUpdater?
  /// Whether to leave the agents running, answered before an update relaunched the application:
  /// the quit that follows does not ask a second time.
  private var decidedForUpdate: Bool?
  /// A relaunch being decided — waiting on a sheet, or its question on screen: Sparkle and the
  /// menu can both ask, and the question is asked once.
  private var isDecidingRelaunch = false

  /// Whether this quit is the Mac shutting down, restarting or logging out: nothing survives that,
  /// and a question on screen would hold the logout up for an answer that changes nothing.
  ///
  /// Read from the quit event itself rather than remembered from `willPowerOffNotification`: a
  /// logout another application cancels leaves that notification behind, and every later quit
  /// would have stopped the agents without asking.
  private var isPoweringOff: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    else { return false }
    return [kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].map { OSType($0) }
      .contains(reason)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let environment else { return .terminateNow }
    // Asked a second time — a quit the system retries, a quit the user repeats — the work has
    // already been done, and the reply for it has already been consumed. Another `terminateLater`
    // would wait for an answer nothing is left to send, and the application would never quit.
    guard !hasRepliedToTermination else { return .terminateNow }
    // A quit already on its way — flushing the notes, or asking about them — answers for this one.
    guard !isFlushingNotes else { return .terminateCancel }
    // Answered before an update relaunched the application, for this quit alone: taken whatever
    // happens next, so that a quit cancelled later never leaves an old answer for the next one.
    let decidedForUpdate = self.decidedForUpdate
    self.decidedForUpdate = nil
    guard
      let keepingAgentsRunning = decideAboutRunningAgents(
        in: environment, decidedForUpdate: decidedForUpdate)
    else {
      return .terminateCancel
    }
    isFlushingNotes = true

    // Terminating immediately would orphan the process tree of every open terminal, and leave
    // the next launch without the intention to resume them. The deadline starts after the
    // question: it bounds the tidying, not the time the user takes to answer.
    Task {
      // A template being edited is saved explicitly, so quitting asks what to do with it — before
      // anything is stopped, since Cancel must leave everything as it was.
      guard await confirmTemplateChanges(environment.appModel.templates) else {
        isFlushingNotes = false
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
        return
      }
      // The notes first, and before the deadline starts: the one thing that can be lost here is
      // what the user typed, and they are asked before it is.
      // Bounded: a write stuck on a stalled volume must not keep the application from quitting.
      let unsaved = await environment.appModel.notes.flushAll(deadline: Self.notesDeadline)
      if !unsaved.isEmpty {
        let proceed = confirmQuit(losing: unsaved, names: environment.appModel.sessions)
        guard proceed else {
          isFlushingNotes = false
          NSApplication.shared.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      Task {
        try? await Task.sleep(for: Self.shutdownDeadline)
        guard !hasRepliedToTermination else { return }
        environment.diagnostics.record(.lifecycle, .error, "app.quitDeadlineReached")
        replyToTermination()
      }
      await environment.shutdown(keepingAgentsRunning: keepingAgentsRunning)
      replyToTermination()
    }
    return .terminateLater
  }

  private var isFlushingNotes = false
  /// How long quitting waits for the notes before asking about those still not on disk.
  private static let notesDeadline: Duration = .seconds(2)

  /// Changes to a prompt template are only ever lost on purpose: Save, Don't Save or Cancel, as
  /// for any document. A template that cannot be saved as it is says why, and offers only to go
  /// back to it or to quit without it.
  private func confirmTemplateChanges(_ templates: PromptTemplateLibraryModel) async -> Bool {
    guard templates.isEdited, let editing = templates.editing else { return true }
    let name =
      editing.trimmedName.isEmpty
      ? String(localized: "Untitled Template", comment: "The name of a template that has none yet.")
      : editing.trimmedName
    let alert = NSAlert()
    alert.alertStyle = .warning
    if templates.canSave {
      alert.messageText = String(
        localized: "Save the changes to the template “\(name)” before quitting?",
        comment: "The name of a prompt template.")
      alert.informativeText = String(localized: "Your changes are lost if you don't save them.")
      alert.addButton(withTitle: String(localized: "Save"))
      alert.addButton(withTitle: String(localized: "Cancel"))
      alert.addButton(withTitle: String(localized: "Don't Save")).hasDestructiveAction = true
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        // A save that fails keeps the application open, with the reason in the templates window.
        return await templates.save()
      case .alertThirdButtonReturn:
        return true
      default:
        return false
      }
    }
    let issue = templates.issues.first.map { "\($0.message) \($0.remedy)" }
    alert.messageText = String(
      localized: "The template “\(name)” has changes that can't be saved.",
      comment: "The name of a prompt template.")
    alert.informativeText =
      (issue.map { $0 + " " } ?? "")
      + String(localized: "Go back to it to finish them, or quit without them.")
    // Cancel is the default: Return must not be the key that loses what was typed.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Quit Anyway")).hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
  }

  /// Notes that could not be written are only ever lost on purpose.
  private func confirmQuit(losing unsaved: [NotesDocument], names sessions: [WorkSession]) -> Bool {
    let names = unsaved.map { document in
      sessions.first { $0.id == document.sessionID }?.name
        ?? String(localized: "a session", comment: "Stands for a session whose name is unknown.")
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      names.count == 1
      ? String(
        localized: "The notes of “\(names[0])” couldn't be saved.", comment: "A session's name.")
      : String(localized: "The notes of \(names.count) sessions couldn't be saved.")
    var reason = ""
    if case .failed(let error, _) = unsaved.first?.state {
      reason = (error.errorDescription ?? "") + " "
    }
    alert.informativeText =
      reason
      + String(
        localized: "Copy them before quitting, or what was typed since the last save is lost.")
    // Cancel is the default: Return must not be the key that loses what was typed.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Copy Notes and Quit"))
    alert.addButton(withTitle: String(localized: "Quit Anyway")).hasDestructiveAction = true
    switch alert.runModal() {
    case .alertSecondButtonReturn:
      let text = zip(names, unsaved).map { name, document in
        unsaved.count == 1 ? document.text : "\(name)\n\n\(document.text)"
      }.joined(separator: "\n\n———\n\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      return true
    case .alertThirdButtonReturn:
      return true
    default:
      return false
    }
  }

  /// Whether to leave the agents running, or `nil` when the user cancelled the quit.
  ///
  /// Asked only when there is something to leave: an agent running in the terminal host. The
  /// answer remembered by "Don't ask again" is changed in the settings.
  private func decideAboutRunningAgents(
    in environment: AppEnvironment, decidedForUpdate: Bool?
  ) -> Bool? {
    let count = environment.hostedRunningCount
    guard count > 0, !isPoweringOff else { return false }
    if let decidedForUpdate { return decidedForUpdate }
    // A version set aside by Later is installed as the application quits (#92). One that speaks
    // another core of the host's protocol could not take back agents left running: not offered.
    if let ready = updater?.readyToInstall,
      let speaks = ready.hostProtocol, speaks != TerminalHost.protocolVersion
    {
      if environment.appModel.quitBehavior == .stopAll { return false }
      return confirmStopping(for: ready) ? false : nil
    }
    switch environment.appModel.quitBehavior {
    case .keepRunning: return true
    case .stopAll: return false
    case .ask: break
    }

    let alert = NSAlert()
    alert.messageText =
      count == 1
      ? String(localized: "An agent is still running.")
      : String(localized: "Agents are running in \(count) sessions.")
    var information = String(
      localized: """
        You can leave them working in the background and find them as they are the next time you \
        open Vibe Manager. A restart of the Mac stops them.
        """)
    // Left running, they keep the access they started with: a host from before the grant carries
    // on without it, and "Quit & Reopen" in System Settings would not change that (#76).
    if case .pendingRestart(.host, _) = environment.permissions.situation {
      information +=
        "\n\n"
        + String(
          localized: """
            They still won't have Full Disk Access when you reopen Vibe Manager: stop them to \
            restart them with it.
            """)
    }
    // Their side terminals follow them either way (#43): a dev server in one is part of the answer.
    if environment.terminals.runningTerminalCount > 0 {
      information +=
        "\n\n"
        + String(
          localized: """
            Their side terminals follow them: left running with them, or stopped with them.
            """)
    }
    let inProcess = environment.inProcessRunningCount
    if inProcess > 0 {
      information +=
        "\n\n"
        + String(
          localized: "\(inProcess) other agents run inside Vibe Manager and will stop either way.")
    }
    alert.informativeText = information
    alert.addButton(withTitle: String(localized: "Keep Running"))
    alert.addButton(withTitle: String(localized: "Stop All"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = String(localized: "Don't ask again")

    let keep: Bool
    switch alert.runModal() {
    case .alertFirstButtonReturn: keep = true
    case .alertSecondButtonReturn: keep = false
    default: return nil
    }
    if alert.suppressionButton?.state == .on {
      environment.appModel.quitBehavior = keep ? .keepRunning : .stopAll
    }
    return keep
  }

  // MARK: - Updates (#92)

  /// Starts the updater, or says why this copy has none.
  func startUpdates(in environment: AppEnvironment) -> UpdatesModel {
    // The channel is kept with the copy's other choices: an isolated copy testing an update must
    // not move the real application to another channel.
    let updater = SparkleSoftwareUpdater(
      defaults: environment.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    self.updater = updater
    updater.isPresentingModal = { Self.isPresentingModal }
    updater.relaunchGate = { [weak self] candidate in
      self?.relaunch(for: candidate)
    }
    // An update that failed after the question: its answer must not stand for a later quit.
    updater.onAbort = { [weak self] in self?.decidedForUpdate = nil }
    let availability: DiagnosticToken =
      switch updater.availability {
      case .available: "available"
      case .unavailable(.developmentBuild): "developmentBuild"
      case .unavailable(.isolatedCopy): "isolatedCopy"
      case .unavailable(.turnedOff): "turnedOff"
      case .unavailable(.notConfigured): "notConfigured"
      case .unavailable(.failed): "failed"
      }
    environment.diagnostics.record(
      .lifecycle, updater.availability == .available ? .info : .notice, "update.availability",
      ["state": .token(availability)])
    return UpdatesModel(updater: updater)
  }

  /// A sheet or an alert is open somewhere: the user is in the middle of something.
  private static var isPresentingModal: Bool {
    NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
  }

  /// An update is ready to relaunch the application. Installing is quitting: the question of
  /// ADR 0017 is asked first, and its answer stands for the quit that follows. Put off while
  /// sessions are being restored or a sheet is open; never installed by "Later", until the next quit.
  private func relaunch(for candidate: UpdateCandidate) {
    guard !isDecidingRelaunch else { return }
    isDecidingRelaunch = true
    decideRelaunch(for: candidate)
  }

  private func decideRelaunch(for candidate: UpdateCandidate) {
    // Given up on meanwhile, or already on its way: nothing is left to answer for.
    guard let updater, updater.readyToInstall == candidate, updater.canOfferReadyUpdate else {
      isDecidingRelaunch = false
      return
    }
    guard let environment else {
      isDecidingRelaunch = false
      updater.installReadyUpdate()
      return
    }
    let situation = UpdateRelaunchSituation(
      hostedRunningCount: environment.hostedRunningCount,
      inProcessRunningCount: environment.inProcessRunningCount,
      quitBehavior: environment.appModel.quitBehavior,
      isRestoring: environment.appModel.restoration != nil,
      isPresentingModal: Self.isPresentingModal,
      currentHostProtocol: TerminalHost.protocolVersion,
      candidate: candidate)
    switch DecideUpdateRelaunch.decide(situation) {
    case .wait:
      // Looked at again without a word: the user asked for it, and nothing was said yet.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(1))
        self?.decideRelaunch(for: candidate)
      }
    case .proceed(let keepingAgentsRunning):
      install(keepingAgentsRunning: keepingAgentsRunning, in: environment)
    case .ask(let question):
      let answer = ask(question, installing: candidate, in: environment)
      // Given up on while the question was on screen: the answer has nothing to apply to.
      guard updater.readyToInstall == candidate, updater.canOfferReadyUpdate else {
        isDecidingRelaunch = false
        return
      }
      guard let keepingAgentsRunning = answer else {
        isDecidingRelaunch = false
        record("later", in: environment)
        // Sparkle's window would otherwise wait on a relaunch nobody starts, and never close.
        updater.setReadyUpdateAside()
        return
      }
      install(keepingAgentsRunning: keepingAgentsRunning, in: environment)
    }
  }

  /// The answer stands for the quit that follows only if the installation really starts it: an
  /// answer left behind would be applied, unasked, to a later quit of the user's own.
  private func install(keepingAgentsRunning: Bool, in environment: AppEnvironment) {
    isDecidingRelaunch = false
    decidedForUpdate = keepingAgentsRunning
    guard updater?.installReadyUpdate() == true else {
      decidedForUpdate = nil
      return
    }
    record(keepingAgentsRunning ? "keepRunning" : "stopAll", in: environment)
  }

  /// Quitting with a version set aside that cannot take back the running agents: stopping them is
  /// the only way on, and it is asked. `false` is Cancel.
  private func confirmStopping(for ready: UpdateCandidate) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
      localized: "Vibe Manager \(ready.version) will be installed as Vibe Manager quits.",
      comment: "The version about to be installed.")
    alert.informativeText = String(
      localized: """
        It can't take back the running agents: they will be stopped, then resumed at the next \
        launch where their conversation left off. The turn in progress is lost.
        """)
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Stop All and Quit")).hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
  }

  private func record(_ answer: DiagnosticToken, in environment: AppEnvironment) {
    environment.diagnostics.record(
      .lifecycle, .notice, "update.relaunch",
      ["answer": .token(answer), "running": .count(environment.hostedRunningCount)])
  }

  /// The quit question, said of an update. `nil` is Later.
  private func ask(
    _ question: UpdateRelaunchDecision.Question, installing candidate: UpdateCandidate,
    in environment: AppEnvironment
  ) -> Bool? {
    let alert = NSAlert()
    switch question {
    case .keepOrStop(let running, let inProcess):
      alert.messageText = String(
        localized: "Install Vibe Manager \(candidate.version) and relaunch?",
        comment: "The version about to be installed.")
      var information =
        running == 1
        ? String(
          localized: """
            An agent is running. It can keep working during the update, and you will find it as it \
            is after the relaunch.
            """)
        : String(
          localized: """
            Agents are running in \(running) sessions. They can keep working during the update, \
            and you will find them as they are after the relaunch.
            """)
      if environment.terminals.runningTerminalCount > 0 {
        information +=
          "\n\n"
          + String(
            localized: """
              Their side terminals follow them: left running with them, or stopped with them.
              """)
      }
      if inProcess > 0 {
        information +=
          "\n\n"
          + String(
            localized: "\(inProcess) other agents run inside Vibe Manager and will stop either way."
          )
      }
      alert.informativeText = information
      alert.addButton(withTitle: String(localized: "Keep Running and Install"))
      alert.addButton(withTitle: String(localized: "Stop All and Install"))
      alert.addButton(withTitle: String(localized: "Later"))
      switch alert.runModal() {
      case .alertFirstButtonReturn: return true
      case .alertSecondButtonReturn: return false
      default: return nil
      }
    case .mustStop(let running):
      alert.alertStyle = .warning
      alert.messageText = String(
        localized: "Vibe Manager \(candidate.version) can't take back the running agents.",
        comment: "The version about to be installed.")
      alert.informativeText = String(
        localized: """
          The \(running) running agents will be stopped, then resumed after the relaunch where \
          their conversation left off. The turn in progress is lost.
          """)
      alert.addButton(withTitle: String(localized: "Later"))
      alert.addButton(withTitle: String(localized: "Stop All and Install"))
        .hasDestructiveAction = true
      return alert.runModal() == .alertSecondButtonReturn ? false : nil
    }
  }

  /// Answered once, whichever of the two tasks gets here first.
  private func replyToTermination() {
    guard !hasRepliedToTermination else { return }
    hasRepliedToTermination = true
    environment?.diagnostics.flush()
    NSApplication.shared.reply(toApplicationShouldTerminate: true)
  }
}
