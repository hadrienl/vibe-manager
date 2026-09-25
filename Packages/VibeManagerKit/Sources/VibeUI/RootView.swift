import Foundation
import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

public struct RootView: View {
  private let model: AppModel
  /// The widths the columns open at, taken once the stored layout has been read and then left
  /// alone. Handing the measured width back as the column's ideal width would close the loop —
  /// measure, store, propose again, resize — and fight the drag the user is in the middle of.
  @State private var idealWidths: IdealColumnWidths?
  /// The "Don't ask again" box of the close confirmation, unticked each time it opens.
  @State private var suppressesCloseConfirmation = false
  /// The window this view is drawn in: the only one whose visibility says whether its sessions
  /// are in front of the user.
  @State private var hostWindow = HostWindow()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        ProgressView {
          Text("Loading sessions…", bundle: .module)
        }
        .controlSize(.large)
      case .loaded:
        workspace
      case .failed(let message, let canRestoreBackup):
        ContentUnavailableView {
          Label(
            LocalizedStringResource("Sessions unavailable", bundle: .module),
            systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          if canRestoreBackup {
            Button(LocalizedStringResource("Restore Backup", bundle: .module)) {
              Task { await model.restoreBackup() }
            }
            .buttonStyle(.borderedProminent)
          }
          Button(LocalizedStringResource("Try Again", bundle: .module)) {
            Task { await model.reload() }
          }
          if model.canExportDiagnostics {
            Button(LocalizedStringResource("Export Diagnostics…", bundle: .module)) {
              model.beginDiagnosticsExport()
            }
          }
        }
      }
    }
    // Narrower than the two sidebars plus a usable terminal on purpose: below the layout
    // thresholds the columns fold, and the window is still worth opening.
    .frame(minWidth: 640, minHeight: 480)
    .task {
      await model.load()
      idealWidths = IdealColumnWidths(
        sidebar: model.layout.intent.sidebarWidth,
        inspector: model.layout.intent.inspectorWidth
      )
    }
    // Back from sleep, or from another application: an event may have been missed meanwhile.
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.applicationDidBecomeActive() }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
    ) {
      _ in model.applicationWillResignActive()
    }
    .sheet(
      item: Binding(
        get: { presentedSheet },
        set: { sheet in
          guard sheet == nil else { return }
          dismissPresentedSheet()
        }
      )
    ) { sheet in
      switch sheet {
      case .fullDiskAccess:
        if let permissions = model.permissions {
          FullDiskAccessSheet(
            openSystemSettings: {
              Task { await permissions.answerStepByOpeningSystemSettings() }
            },
            skip: { Task { await permissions.skipStep() } }
          )
        }
      case .newSession:
        if let sheetModel = model.newSessionModel {
          NewSessionSheet(
            model: sheetModel,
            defaultWorkingDirectoryPath: model.newSessionDefaultWorkingDirectoryPath,
            created: { creation, launching in
              Task { await model.complete(creation, launching: launching) }
            },
            cancelled: { model.cancelNewSession() },
            manageTemplates: {
              model.settingsTab = .templates
              openSettings()
            }
          )
        }
      case .restartContext:
        // A fresh start is the one restart that sends something: the text is shown before it
        // goes, and the sheet is where it can still be changed or called off.
        if let pending = model.pendingRestart {
          RestartContextSheet(
            pending: pending,
            restart: { text in Task { await model.confirmRestart(text) } },
            cancel: { model.cancelRestart() }
          )
          // Keyed on the session: the editor holds its text in `@State`, seeded once, so a sheet
          // re-presented for another session would open on the previous session's summary.
          .id(pending.sessionID)
        }
      case .agentSwitch:
        if let sheetModel = model.pendingSwitch {
          AgentSwitchSheet(
            model: sheetModel,
            confirm: { Task { await model.confirmAgentSwitch() } },
            cancel: { model.cancelAgentSwitch() }
          )
          .id(sheetModel.sessionID)
        }
      case .diagnosticsExport:
        if let export = model.diagnosticsExport {
          DiagnosticsExportSheet(model: export, close: { model.endDiagnosticsExport() })
            .id(export.id)
        }
      case .hookConsent:
        if let request = model.hookConsentRequest {
          HookConsentSheet(request: request, answer: { model.answerHookConsent($0) })
            .id(request.id)
        }
      }
    }
    // An answer finished while the window is out of sight is unread: minimised, hidden or
    // covered, it is not in front of the user.
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
    ) { notification in
      // Settings, Usage, a panel or a sheet coming and going says nothing about this window.
      guard let window = notification.object as? NSWindow, window === hostWindow.window else {
        return
      }
      model.mainWindowVisibilityChanged(window.occlusionState.contains(.visible))
    }
    .background(HostWindowReader(host: hostWindow))
  }

  private func session(_ id: SessionID?) -> WorkSession? {
    id.flatMap { id in model.sessions.first { $0.id == id } }
  }

  private func switchAction(for id: SessionID?) -> (() -> Void)? {
    guard let session = session(id), model.canSwitchAgent(session) else { return nil }
    return { model.beginAgentSwitch(session.id) }
  }

  private func restartAction(for id: SessionID?) -> (() -> Void)? {
    guard let session = session(id), model.canRestart(session) else { return nil }
    return { Task { await model.restart(session.id) } }
  }

  /// Which sheet the window is showing, out of the ones asking to be shown.
  ///
  /// One modifier, not two. SwiftUI presents a single sheet per view and drops the rest on the
  /// floor: stacked, a ⌘N pressed while the launch step is up left the model believing the New
  /// Session sheet was open and the user looking at nothing. Ordered rather than exclusive, so
  /// that ⌘N is not lost either — the step is answered first, and the sheet it delayed opens next.
  private var presentedSheet: RootSheet? {
    if model.permissions?.isPresentingStep == true { return .fullDiskAccess }
    if model.isPresentingNewSession { return .newSession }
    if model.pendingRestart != nil { return .restartContext }
    if model.pendingSwitch != nil { return .agentSwitch }
    if model.diagnosticsExport != nil { return .diagnosticsExport }
    if model.hookConsentRequest != nil { return .hookConsent }
    return nil
  }

  /// Reached when the sheet is closed by the window rather than by one of its own buttons — Escape
  /// or a click outside. Closing is an answer in both cases, and it is the one already written for
  /// each: skipping the step, cancelling the draft.
  private func dismissPresentedSheet() {
    switch presentedSheet {
    case .fullDiskAccess:
      guard let permissions = model.permissions else { return }
      Task { await permissions.skipStep() }
    case .newSession:
      model.cancelNewSession()
    case .restartContext:
      model.cancelRestart()
    case .agentSwitch:
      model.cancelAgentSwitch()
    case .diagnosticsExport:
      model.endDiagnosticsExport()
    case .hookConsent:
      // Closed without a button: no answer, which nothing remembers.
      model.answerHookConsent(.undecided)
    case nil:
      break
    }
  }

  /// Shown at launch and nowhere else. The alerts the step exists to replace fall in the middle of
  /// creating a session, which is precisely where this question must never be asked.
  private enum RootSheet: Identifiable {
    case fullDiskAccess
    case newSession
    /// Presented from the root rather than from the workspace: attached to the loaded column it
    /// was torn down by a refresh that failed, leaving a pending restart nobody could answer or
    /// call off — and a session whose Restart command stayed withheld.
    case restartContext
    /// Presented from the root for the same reason as the restart's summary.
    case agentSwitch
    /// From the Help menu, Settings, or a store that could not be read: the last case has no
    /// workspace to attach a sheet to.
    case diagnosticsExport
    /// A launch waits on it: asked before a CLI's hooks are approved.
    case hookConsent

    var id: Self { self }
  }

  private var workspace: some View {
    NavigationSplitView(columnVisibility: sidebarVisibility) {
      SessionSidebar(model: model)
        .navigationSplitViewColumnWidth(
          min: WorkspaceLayout.sidebarWidthRange.lowerBound,
          ideal: idealWidths?.sidebar ?? model.layout.intent.sidebarWidth,
          max: WorkspaceLayout.sidebarWidthRange.upperBound
        )
        .background(WidthReporter { model.layout.sidebarWidthChanged(to: $0) })
    } detail: {
      VStack(spacing: 0) {
        if let failure = model.refreshFailure {
          RefreshFailureBanner(
            failure: failure,
            retry: { Task { await model.reload() } },
            restore: { Task { await model.restoreBackup() } },
            export: model.canExportDiagnostics ? { model.beginDiagnosticsExport() } : nil,
            dismiss: { model.dismissRefreshFailure() }
          )
          Divider()
        }
        if let warning = model.detachWarning {
          DetachWarningBanner(warning: warning) { model.dismissDetachWarning() }
          Divider()
        }
        if let failure = model.restartFailure {
          RestartFailureBanner(
            failure: failure,
            detect: { Task { await model.refreshAgents(forceRefresh: true) } },
            isDetecting: model.isRefreshingAgents,
            restart: nil,
            // An agent that cannot run is exactly when another one is wanted — for the session
            // the banner names, whichever one is selected by now.
            switchAgent: switchAction(for: failure.sessionID),
            dismiss: { model.dismissRestartFailure() }
          )
          Divider()
        }
        if let failure = model.switchFailure {
          RestartFailureBanner(
            failure: failure,
            detect: { Task { await model.refreshAgents(forceRefresh: true) } },
            isDetecting: model.isRefreshingAgents,
            // Back on its previous agent, the session resumes its own conversation with Restart;
            // or another switch can be tried.
            restart: restartAction(for: failure.sessionID),
            switchAgent: switchAction(for: failure.sessionID),
            dismiss: { model.dismissSwitchFailure() }
          )
          Divider()
        }
        // The four faces of #11, and only ever one of them at a time: a restoration running, one
        // offered after an unexpected stop, a second copy of the application holding the
        // sessions, or the account of what did not come back.
        if let restoration = model.restoration {
          RestorationBanner(restoration: restoration, cancel: { model.cancelRestore() })
          Divider()
        }
        if let offer = model.restoreOffer {
          RestoreOfferBanner(
            offer: offer,
            resume: { Task { await model.acceptRestoreOffer() } },
            dismiss: { model.dismissRestoreOffer() }
          )
          Divider()
        }
        if let processIdentifier = model.otherInstanceProcessIdentifier {
          OtherInstanceBanner(
            processIdentifier: processIdentifier,
            dismiss: { model.dismissOtherInstanceNotice() }
          )
          Divider()
        }
        if let report = model.restoreReport {
          RestoreReportBanner(report: report, dismiss: { model.dismissRestoreReport() })
          Divider()
        }
        if let reason = model.hostUnavailableReason {
          HostUnavailableBanner(
            reason: reason,
            isRetrying: model.isRetryingHost,
            retry: { Task { await model.retryHostReattach() } },
            dismiss: { model.dismissHostUnavailableNotice() }
          )
          Divider()
        }
        if let notice = model.detachedNotice {
          DetachedNoticeBanner(notice: notice, dismiss: { model.dismissDetachedNotice() })
          Divider()
        }
        detail
      }
      // No shortcut here: ⌘N belongs to the New Session menu command, which owns it for the
      // whole application. Repeating it bound the same key twice, under two conditions.
      .toolbar {
        // Where the work on the session on screen stands, and a way to change it (#80).
        ToolbarItem(placement: .primaryAction) {
          if let session = model.selectedSession, session.taskStatus != .archived {
            TaskStatusMenu(commands: SessionCommands(model: model, session: session))
          }
        }
        ToolbarItem(placement: .principal) {
          if let session = model.selectedSession, model.conversations.canShowConversation(session) {
            PresentationPicker(
              selection: Binding(
                get: { model.presentation(of: session) },
                set: { model.setPresentation($0, of: session.id) }))
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            model.beginNewSession()
          } label: {
            Label(LocalizedStringResource("New Session", bundle: .module), systemImage: "plus")
          }
          .disabled(!model.canCreateSession)
        }
        if model.browser != nil {
          // In a window too narrow for both, the terminal and the web view take turns, and this
          // is where the user picks which one (#69).
          if model.layout.columns.browser == .alternating {
            ToolbarItem(placement: .principal) {
              Picker(
                selection: Binding(
                  get: { model.layout.showsBrowserWhenAlternating },
                  set: { showsBrowser in
                    model.layout.setShowsBrowserWhenAlternating(showsBrowser)
                    if !showsBrowser { model.focusTerminal() }
                  })
              ) {
                Text("Terminal", bundle: .module).tag(false)
                Text("Web", bundle: .module).tag(true)
              } label: {
                Text("Main View", bundle: .module)
              }
              .pickerStyle(.segmented)
              .fixedSize()
            }
          }
          ToolbarItem(placement: .primaryAction) {
            Button {
              model.toggleWebView()
            } label: {
              Label(
                model.isWebViewOpen
                  ? LocalizedStringResource(
                    "Hide Web View", bundle: .module,
                    comment: "Hides the session's web view beside its terminal.")
                  : LocalizedStringResource(
                    "Show Web View", bundle: .module,
                    comment: "Shows the session's web view beside its terminal."),
                systemImage: "globe"
              )
            }
            .disabled(!model.isWebViewAvailable)
            .accessibilityValue(
              model.isWebViewOpen
                ? Text("Shown", bundle: .module, comment: "The web view is shown.")
                : Text("Hidden", bundle: .module, comment: "The web view is hidden."))
          }
        }
        ToolbarItem(placement: .primaryAction) {
          // Never disabled: with the column open and the selection gone, a disabled button
          // would be the only way to close it. The column says so itself instead.
          Button {
            model.layout.toggleInspector()
          } label: {
            Label(
              model.layout.columns.isInspectorVisible
                ? LocalizedStringResource(
                  "Hide Context", bundle: .module, comment: "Hides the inspector of the window.")
                : LocalizedStringResource(
                  "Show Context", bundle: .module, comment: "Shows the inspector of the window."),
              systemImage: "sidebar.right"
            )
          }
          .accessibilityValue(
            model.layout.columns.isInspectorVisible
              ? Text("Shown", bundle: .module, comment: "The inspector is shown.")
              : Text("Hidden", bundle: .module, comment: "The inspector is hidden."))
        }
      }
      .inspector(isPresented: inspectorPresented) {
        Group {
          if let session = model.selectedSession {
            SessionContextInspector(
              session: session,
              resolution: model.resolution(forID: session.id),
              branchReport: model.branchReport(for: session.id),
              repositoryStatuses: model.repositoryStatuses,
              sessionNames: Dictionary(
                model.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
              refreshBranches: model.reportsBranches
                ? { Task { await model.refreshBranchReport() } } : nil,
              git: model.gitInspector,
              split: model.layout.intent.inspectorSplit,
              splitChanged: { model.layout.inspectorSplitChanged(to: $0) },
              openPrivacySettings: model.permissions.map { permissions in
                { permissions.openSystemSettings() }
              },
              agentNames: model.agentNames,
              switchAgent: model.canSwitchAgent(session)
                ? { model.beginAgentSwitch(session.id) } : nil,
              notes: model.notes,
              leaveNotes: { model.focusTerminal() },
              usage: model.usage,
              isDetailsExpanded: model.layout.intent.isSessionDetailsExpanded,
              detailsExpandedChanged: { model.layout.setSessionDetailsExpanded($0) },
              journal: model.journal,
              topTab: model.layout.intent.inspectorTopTab,
              topTabChanged: { model.layout.setInspectorTopTab($0) }
            )
          } else {
            // The inspector is only reachable with a selection, but a session can disappear
            // under it: the column stays rather than snapping shut mid-refresh.
            ContentUnavailableView {
              Label {
                Text("No session selected", bundle: .module)
              } icon: {
                Image(systemName: "sidebar.right")
              }
            } description: {
              Text("Select a session to see its repositories and notes.", bundle: .module)
            }
          }
        }
        .inspectorColumnWidth(
          min: WorkspaceLayout.inspectorWidthRange.lowerBound,
          ideal: idealWidths?.inspector ?? model.layout.intent.inspectorWidth,
          max: WorkspaceLayout.inspectorWidthRange.upperBound
        )
        .background(WidthReporter { model.layout.inspectorWidthChanged(to: $0) })
      }
    }
    // Measured on the whole split view: which columns fit is a question about the window, and
    // the answer has to be known before either column decides whether to draw itself.
    .background(WidthReporter { model.layout.windowWidthChanged(to: $0) })
    // Only asked when an agent is running: the one thing closing loses is the work it is doing.
    // `presenting:` for the same reason as the archive dialog below.
    .confirmationDialog(
      model.pendingClose.map {
        Text("Close “\($0.name)”?", bundle: .module, comment: "A session's name.")
      } ?? Text("Close this session?", bundle: .module),
      isPresented: Binding(
        get: { model.pendingClose != nil },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelClose()
        }
      ),
      titleVisibility: .visible,
      presenting: model.pendingClose
    ) { session in
      Button(LocalizedStringResource("Close Session", bundle: .module)) {
        let askAgain = !suppressesCloseConfirmation
        Task { await model.confirmClose(session.id, askAgain: askAgain) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelClose()
      }
    } message: { _ in
      Text("The agent will be stopped. The session can be restarted later.", bundle: .module)
    }
    // Before the archive dialog in the chain: the toggle reaches every dialog it wraps, and the
    // archive question has no "Don't ask again".
    .dialogSuppressionToggle(
      Text("Don’t ask again", bundle: .module), isSuppressed: $suppressesCloseConfirmation
    )
    .onChange(of: model.pendingClose?.id) { _, id in
      if id != nil { suppressesCloseConfirmation = false }
    }
    // Archiving is reversible, so the question is short and says what actually happens. Cancel
    // is the default button: the pointer slip that opened this must not also answer it.
    // `presenting:` hands the session to the buttons, rather than having them read it back from
    // the model. SwiftUI dismisses the dialog before running a button's action, and the dismissal
    // clears the pending session — read there, Archive found nothing and did nothing.
    .confirmationDialog(
      model.pendingArchive.map {
        Text("Archive “\($0.name)”?", bundle: .module, comment: "A session's name.")
      } ?? Text("Archive this session?", bundle: .module),
      isPresented: Binding(
        get: { model.pendingArchive != nil },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelArchive()
        }
      ),
      titleVisibility: .visible,
      presenting: model.pendingArchive
    ) { session in
      Button(LocalizedStringResource("Archive", bundle: .module)) {
        Task { await model.archive(session.id) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelArchive()
      }
    } message: { session in
      Text(archiveConfirmationMessage(for: session))
    }
  }

  private func archiveConfirmationMessage(for session: WorkSession) -> String {
    let isRunning = model.pane(for: session.id)?.status == .running
    let consequence = String(
      localized: """
        Nothing is deleted: notes, repositories and Git metadata are kept, and the session stays \
        readable under Archived. It can no longer be reopened until it is unarchived.
        """,
      bundle: .module,
      comment: "Archived is the line at the foot of the sidebar that lists archived sessions.")
    guard isRunning else { return consequence }
    return String(localized: "Its running agent will be stopped.", bundle: .module) + " "
      + consequence
  }

  /// `.detailOnly` is the only hidden state worth recording; the others all show the sidebar.
  private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.layout.columns.isSidebarVisible ? .all : .detailOnly },
      set: { model.layout.setSidebarVisible($0 != .detailOnly) }
    )
  }

  private var inspectorPresented: Binding<Bool> {
    Binding(
      get: { model.layout.columns.isInspectorVisible },
      set: { model.layout.setInspectorVisible($0) }
    )
  }

  @ViewBuilder
  private var detail: some View {
    if let session = model.selectedSession {
      // Every terminal stays mounted, and changing session only changes which one is shown.
      // Rebuilding the selected one instead meant a fresh, empty terminal for the frame it
      // took to replay the history — and it threw away the scroll position with it.
      //
      // The panes stay mounted even when the selected session has none: selecting a session
      // restored from the store without a terminal used to take the whole stack down with it,
      // and its neighbours came back scrolled to the bottom.
      VStack(spacing: 0) {
        // A closed session keeps its terminal on screen, so the way back to work has to be on
        // screen too — next to what the agent said last, not only in a menu.
        // The archive card is what the terminal side shows; over a conversation, the same way
        // back sits above it.
        if session.status == .archived, model.presentation(of: session) == .conversation {
          ArchivedConversationBar { Task { await model.restore(session.id) } }
          Divider()
        }
        if session.status == .closed {
          ClosedSessionBar(
            title: model.restartTitle(for: session),
            isRestarting: model.restartingSessionIDs.contains(session.id),
            canRestart: model.canRestart(session),
            restart: { Task { await model.restart(session.id) } },
            switchBack: model.switchBackOffers[session.id].flatMap { offer in
              model.canSwitchAgent(session)
                ? (offer.label, { model.switchBack(session.id) }) : nil
            }
          )
          Divider()
        }
        // Said where the agent is, and only when it is true: the user who counts on leaving it
        // running when they quit must learn now that this one cannot be.
        if model.willStopWithApplication(session.id) {
          InProcessAgentBar()
          Divider()
        }
        sessionContent(for: session)
      }
    } else {
      ContentUnavailableView {
        Label(
          LocalizedStringResource("No session yet", bundle: .module),
          systemImage: "square.stack.3d.up")
      } description: {
        Text("Create one to start a terminal and its coding agent.", bundle: .module)
      } actions: {
        Button(LocalizedStringResource("New Session", bundle: .module)) {
          model.beginNewSession()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canCreateSession)
      }
    }
  }

  /// About eighty columns at the terminal's default font: the web view never takes more.
  private static let terminalMinimumWidth: Double = 560

  /// The terminal, and the web view beside it or in turns with it (#69).
  ///
  /// The terminal is never taken out of the hierarchy, nor narrowed to nothing: when the web view
  /// takes its place, it is drawn over it. A terminal resized to zero columns would tell its agent
  /// so, and every full-screen program in it would redraw for a window it does not have.
  @ViewBuilder
  private func sessionContent(for session: WorkSession) -> some View {
    if let workspace = model.browser, session.status != .archived {
      let browser = workspace.browser(for: session.id)
      switch model.layout.columns.browser {
      case .hidden:
        terminalStack(for: session)
      case .beside:
        GeometryReader { proxy in
          // The terminal keeps its eighty columns: the web view gives way first.
          let available =
            Double(proxy.size.width) - Self.terminalMinimumWidth
            - Double(SplitHandle.thickness)
          let upper = max(WorkspaceLayout.browserWidthRange.lowerBound, available)
          let width = min(model.layout.browserWidth, upper)
          HStack(spacing: 0) {
            terminalStack(for: session)
            SplitHandle(
              width: width,
              range: WorkspaceLayout.browserWidthRange.lowerBound...upper,
              label: Text("Divider between the terminal and the web view", bundle: .module),
              onChange: { model.layout.browserWidthChanged(to: $0) })
            BrowserPanel(model: model, workspace: workspace, browser: browser)
              .frame(width: width)
          }
        }
      case .alternating:
        ZStack {
          terminalStack(for: session)
          if model.layout.showsBrowserWhenAlternating {
            BrowserPanel(model: model, workspace: workspace, browser: browser)
          }
        }
      }
    } else {
      terminalStack(for: session)
    }
  }

  /// "Terminal — <session> — <what its agent is doing>".
  private func terminalTitle(for session: WorkSession, pane: TerminalPaneModel) -> String {
    let status = SessionStatusPresentation.make(
      session: session,
      paneStatus: pane.status,
      resolution: model.resolution(forID: session.id),
      wasStoppedOnPurpose: pane.wasStoppedOnPurpose,
      activity: model.activity(for: session.id)
    )
    return String(
      localized: "Terminal — \(session.name) — \(String(localized: status.label))",
      bundle: .module,
      comment: "What VoiceOver calls a terminal: the session's name, then its state.")
  }

  /// The theme of the conversation views, for the system's appearance of the moment.
  private var conversationTheme: ConversationTheme {
    ConversationTheme.resolve(
      ConversationFonts.installedOnly(model.conversations.appearance),
      isDark: colorScheme == .dark, increasedContrast: colorSchemeContrast == .increased)
  }

  @ViewBuilder
  private func terminalStack(for session: WorkSession) -> some View {
    let presentation = model.presentation(of: session)
    ZStack {
      ForEach(model.sessions) { listed in
        if let pane = model.pane(for: listed.id) {
          let isActive = listed.id == session.id && model.presentation(of: listed) == .terminal
          // Started by the launcher, so switching sessions never restarts an agent.
          TerminalPaneView(
            model: pane, autoStart: false, isActive: isActive,
            accessibilityTitle: terminalTitle(for: listed, pane: pane)
          )
          .id(listed.id)
          .opacity(isActive ? 1 : 0)
          .allowsHitTesting(isActive)
          .accessibilityHidden(!isActive)
        }
      }

      // Mounted like the terminals, so that going back and forth keeps each one's place. Only
      // the few sessions last shown in conversation keep one.
      ForEach(model.conversations.mountedSessionIDs, id: \.self) { id in
        if let conversation = model.conversations.existingModel(for: id),
          let listed = model.sessions.first(where: { $0.id == id })
        {
          let isActive = id == session.id && model.presentation(of: listed) == .conversation
          ConversationView(
            model: conversation, theme: conversationTheme,
            appearance: model.conversations.appearance
          )
          .opacity(isActive ? 1 : 0)
          .allowsHitTesting(isActive)
          .accessibilityHidden(!isActive)
          // A hidden composer must lose the keyboard: typed into, it would send to a session
          // nobody is looking at.
          .disabled(!isActive)
        }
      }

      // An archived session has no pane by construction — archiving released it — so its own
      // card is what the column shows, rather than the "no terminal" message of a session
      // that simply has not been started.
      if presentation == .conversation {
        EmptyView()
      } else if session.status == .archived {
        ArchivedSessionDetail(session: session) {
          Task { await model.restore(session.id) }
        }
      } else if model.pane(for: session.id) == nil {
        ContentUnavailableView {
          Label(session.name, systemImage: session.appearance.symbolName)
        } description: {
          Text(
            model.launchFailure(for: session.id)?.message
              ?? String(
                localized: "This session has no running terminal in this window.",
                bundle: .module)
          )
        } actions: {
          if let suggestion = model.launchFailure(for: session.id)?.suggestion {
            Text(suggestion)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .background(.background)
      }
    }
    .task(id: ConversationShowKey(session: session, presentation: presentation)) {
      if presentation == .conversation { model.conversations.show(session) }
    }
    // Takes the whole column even with nothing mounted in it. A terminal fills it on its own,
    // but a window where no session has a pane yet — every one of them closed, straight after a
    // relaunch — left this stack at the size of its "no terminal" card, and the bar above it was
    // then centred in the column instead of sitting under the toolbar.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The status of the session on screen, in the toolbar, as a menu of the four columns.
private struct TaskStatusMenu: View {
  let commands: SessionCommands

  var body: some View {
    let current = commands.taskStatus
    Menu {
      ForEach(commands.movableStatuses, id: \.self) { status in
        Toggle(
          status.label,
          isOn: Binding(
            get: { current == status },
            set: { isOn in if isOn { commands.setTaskStatus(status) } }
          )
        )
      }
    } label: {
      Label {
        Text(current.label)
      } icon: {
        Image(systemName: current.symbolName)
          .foregroundStyle(current.tint)
      }
      .labelStyle(.titleAndIcon)
    }
    .help(
      Text("Status", bundle: .module, comment: "The submenu that moves a session between columns.")
    )
    .accessibilityLabel(
      Text(
        "Status: \(String(localized: current.label))", bundle: .module,
        comment: "The toolbar menu of a session's task status.")
    )
    .accessibilityIdentifier("task-status-menu")
  }
}

/// What a closed session offers above its terminal: the way back to work.
private struct ClosedSessionBar: View {
  let title: String
  let isRestarting: Bool
  let canRestart: Bool
  let restart: () -> Void
  /// The agent a switch left, offered back when the new one stopped at once.
  var switchBack: (label: String, action: () -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "stop.circle")
        .foregroundStyle(.secondary)
      Text("This session is closed. Everything it carries is kept.", bundle: .module)
        .font(.callout)
      Spacer(minLength: 8)
      if isRestarting {
        ProgressView()
          .controlSize(.small)
        Text("Starting…", bundle: .module)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let switchBack, !isRestarting {
        Button(
          LocalizedStringResource("Switch Back to \(switchBack.label)…", bundle: .module),
          action: switchBack.action
        )
        .controlSize(.small)
      }
      Button(title, action: restart)
        .controlSize(.small)
        // Disabled for as long as the restart is on its way: the window between the command and
        // the first process is exactly where a second click would have forked a second agent.
        .disabled(!canRestart)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
  }
}

/// A restart that never reached a process. It names the session, because the banner outlives the
/// selection that started it.
private struct RestartFailureBanner: View {
  let failure: AppModel.RestartFailure
  let detect: () -> Void
  let isDetecting: Bool
  let restart: (() -> Void)?
  let switchAgent: (() -> Void)?
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "\(failure.sessionName): \(failure.message)", bundle: .module,
          comment: "A session's name, then a sentence about it."
        )
        .font(.callout)
        if let suggestion = failure.suggestion {
          Text(suggestion)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      // Most of these failures are an agent the Mac cannot run right now, and detecting again is
      // what turns that around without leaving the workspace.
      Button(LocalizedStringResource("Detect Again", bundle: .module), action: detect)
        .controlSize(.small)
        .disabled(isDetecting)
      if let restart {
        Button(LocalizedStringResource("Restart", bundle: .module), action: restart)
          .controlSize(.small)
      }
      if let switchAgent {
        Button(LocalizedStringResource("Switch Agent…", bundle: .module), action: switchAgent)
          .controlSize(.small)
      }
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(
      String(
        localized: "\(failure.sessionName): \(failure.message)", bundle: .module,
        comment: "A session's name, then a sentence about it."))
  }
}

/// The one restart that sends something, shown before it is sent.
///
/// The text is editable because the user is the only one who can tell whether a fact recorded
/// days ago still holds. The edit applies to this launch alone: a lasting account of a session
/// is what its notes are for.
private struct RestartContextSheet: View {
  let pending: AppModel.PendingRestart
  let restart: (String) -> Void
  let cancel: () -> Void

  @State private var text: String

  init(
    pending: AppModel.PendingRestart,
    restart: @escaping (String) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.pending = pending
    self.restart = restart
    self.cancel = cancel
    _text = State(initialValue: pending.briefText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Restart “\(pending.sessionName)” in a new process?", bundle: .module)
        .font(.headline)
      Text(explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if pending.carriesContext {
        TextEditor(text: $text)
          .font(.system(.callout, design: .monospaced))
          .frame(minHeight: 220)
          .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
          )
          .accessibilityLabel(Text("Summary sent to the agent", bundle: .module))
        if pending.isTruncated {
          Text("This summary was shortened to fit what the agent accepts.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let leftOut = pending.leftOutNotes {
          Text(leftOut)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack {
        Spacer()
        Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button(LocalizedStringResource("Restart", bundle: .module)) { restart(text) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          // Return belongs to the summary while it is being edited: ⌘↩ restarts from anywhere in
          // the sheet, as it creates from anywhere in the New Session one.
          .background {
            Button(LocalizedStringResource("Restart", bundle: .module)) { restart(text) }
              .keyboardShortcut(.return, modifiers: .command)
              .hidden()
          }
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private var explanation: String {
    guard pending.carriesContext else {
      return String(
        localized: """
          \(pending.explanation) This agent takes no initial prompt either, so the new process \
          starts without any summary of the session.
          """,
        bundle: .module, comment: "Why the conversation cannot be resumed, in one sentence.")
    }
    return String(
      localized: """
        \(pending.explanation) A new process will be started instead, and given this summary of \
        what the session carries. You can edit it before it is sent.
        """,
      bundle: .module, comment: "Why the conversation cannot be resumed, in one sentence.")
  }
}

/// A store failure shown over a workspace that keeps working.
private struct RefreshFailureBanner: View {
  let failure: AppModel.RefreshFailure
  let retry: () -> Void
  let restore: () -> Void
  let export: (() -> Void)?
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(failure.message)
        .font(.callout)
        .lineLimit(2)
      Spacer(minLength: 8)
      if failure.canRestoreBackup {
        Button(LocalizedStringResource("Restore Backup", bundle: .module), action: restore)
          .controlSize(.small)
      }
      Button(LocalizedStringResource("Try Again", bundle: .module), action: retry)
        .controlSize(.small)
      if let export {
        Button(LocalizedStringResource("Export Diagnostics…", bundle: .module), action: export)
          .controlSize(.small)
      }
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(failure.message)
  }
}

/// A restoration under way, with the one thing the user can do about it.
///
/// Cancel empties the queue and touches nothing that is already running: a restoration that
/// could not be interrupted would be an application deciding, for several minutes, what the
/// machine is busy with.
private struct RestorationBanner: View {
  let restoration: AppModel.Restoration
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(restoration.message)
        .font(.callout)
        .lineLimit(1)
      Spacer(minLength: 8)
      Button(LocalizedStringResource("Cancel", bundle: .module), action: cancel)
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(restoration.message)
    // Announced as it moves, once per session rather than once per line of output: the count and
    // the name are what tell a listener that the application is working and on what.
    .accessibilityAddTraits(.updatesFrequently)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(restoration.message)
  }
}

/// An unexpected stop, offering what it left behind instead of taking it upon itself.
private struct RestoreOfferBanner: View {
  let offer: AppModel.RestoreOffer
  let resume: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.arrow.circlepath")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(offer.message)
          .font(.callout)
        if let suggestion = offer.suggestion {
          Text(suggestion)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      Button(LocalizedStringResource("Resume Sessions", bundle: .module), action: resume)
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
      Button(LocalizedStringResource("Ignore", bundle: .module), action: dismiss)
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(offer.message)
  }
}

/// Two copies of the application, and the sessions belong to the other one.
private struct OtherInstanceBanner: View {
  let processIdentifier: Int32
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.on.rectangle")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "Another copy of Vibe Manager (pid \(String(processIdentifier))) is running these sessions.",
          bundle: .module, comment: "The process identifier of the other copy."
        )
        .font(.callout)
        Text(
          "Nothing was restored or changed here. Quit that copy before working from this one.",
          bundle: .module
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(
      String(
        localized:
          "Another copy of Vibe Manager is running these sessions. Nothing was restored or changed here.",
        bundle: .module))
  }
}

/// An agent running inside the application, because the terminal host could not be used.
private struct InProcessAgentBar: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Text("This agent will stop when Vibe Manager quits.", bundle: .module)
        .font(.callout)
      Text("The background terminal host could not be used for it.", bundle: .module)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(.quaternary)
    .accessibilityElement(children: .combine)
  }
}

/// Agents still working in the background whose host would not let this copy reattach.
///
/// Said as it is: they are running, nothing was stopped or closed, and trying again is the way
/// back. Calling it "another copy of Vibe Manager" would be wrong — it is the host.
private struct HostUnavailableBanner: View {
  let reason: String
  let isRetrying: Bool
  let retry: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "Your agents are still running in the background, but Vibe Manager could not reattach.",
          bundle: .module
        )
        .font(.callout)
        Text(
          "\(reason) Nothing was stopped or closed.", bundle: .module,
          comment: "Why the application could not reattach to its agents, in one sentence."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button(
        isRetrying
          ? LocalizedStringResource("Retrying…", bundle: .module)
          : LocalizedStringResource("Retry", bundle: .module),
        action: retry
      )
      .disabled(isRetrying)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(
      String(
        localized:
          "Your agents are still running in the background, but Vibe Manager could not reattach. \(reason)",
        bundle: .module,
        comment: "Why the application could not reattach to its agents, in one sentence."))
  }
}

/// Agents that went on working while the application was closed, back on screen as they are.
private struct DetachedNoticeBanner: View {
  let notice: AppModel.DetachedNotice
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(notice.message)
          .font(.callout)
        if notice.endedCount > 0 {
          Text("A finished session shows its last output, and can be restarted.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(notice.message)
  }
}

/// What a restoration could not bring back, as a list rather than a queue of dialogs.
///
/// Each line says the session, the reason and the way out; the sessions themselves are closed,
/// whole, and one Restart away. Nothing is shown when everything came back.
///
/// Deliberately built from a stack and a button rather than a `DisclosureGroup`. In a banner
/// inside the split view's detail column, the disclosure and the column negotiated a width
/// against each other on every pass: AppKit counted 186 requests to update the window's
/// constraints in a single display cycle, tripped its own loop guard at 180, and threw — which
/// with an application built for development is a crash, seconds after launch.
private struct RestoreReportBanner: View {
  let report: AppModel.RestoreReport
  let dismiss: () -> Void

  @State private var isShowingDetails = true

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(report.message)
          .font(.callout)
        if isShowingDetails {
          ForEach(report.lines) { line in
            VStack(alignment: .leading, spacing: 1) {
              Text(
                "\(line.name): \(line.sentence)", bundle: .module,
                comment:
                  "A session's name, then what happened to it when the sessions were restored."
              )
              .font(.caption)
              if let suggestion = line.suggestion {
                Text(suggestion)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      Spacer(minLength: 8)
      if !report.lines.isEmpty {
        Button(
          isShowingDetails
            ? LocalizedStringResource("Hide Details", bundle: .module)
            : LocalizedStringResource("Show Details", bundle: .module)
        ) {
          isShowingDetails.toggle()
        }
        .controlSize(.small)
      }
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(report.message)
  }
}

/// A stop the system would not confirm, shown over a workspace that keeps working.
private struct DetachWarningBanner: View {
  let warning: AppModel.DetachWarning
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(warning.message)
          .font(.callout)
        Text(warning.suggestion)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    // Said as it appears: VoiceOver does not read what shows up away from its cursor.
    .announcedOnAppear(warning.message)
  }
}

/// What an archived session shows where its terminal used to be.
///
/// It is deliberately a card and not an error: archiving is a decision the user made, so the
/// column states the facts, says plainly that nothing was deleted, and offers the way back.
private struct ArchivedSessionDetail: View {
  let session: WorkSession
  let restore: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "archivebox.fill")
          .foregroundStyle(.secondary)
        Text(
          "This session is archived: nothing was deleted, and it cannot be reopened.",
          bundle: .module
        )
        .font(.callout)
        Spacer(minLength: 8)
        Button(LocalizedStringResource("Unarchive", bundle: .module), action: restore)
          .controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.quaternary)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 10) {
            SessionBadge(appearance: session.appearance)
            VStack(alignment: .leading, spacing: 2) {
              Text(session.name)
                .font(.title3)
                .fontWeight(.semibold)
              if let agent = session.agent {
                Text([agent.providerID, agent.modelID].compactMap { $0 }.joined(separator: " · "))
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
          }

          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            dateRow(
              LocalizedStringResource(
                "Created", bundle: .module, comment: "Labels the date a session was created."),
              session.createdAt)
            if let closedAt = session.closedAt {
              dateRow(
                LocalizedStringResource(
                  "Closed", bundle: .module,
                  comment:
                    "A session's state in the sidebar; also labels the date it took that state."),
                closedAt)
            }
            if let archivedAt = session.archivedAt {
              dateRow(
                LocalizedStringResource(
                  "Archived", bundle: .module,
                  comment:
                    "A session's state in the sidebar; also labels the date it took that state."),
                archivedAt)
            }
          }
          .font(.callout)

          Text(
            """
            Repositories, Git metadata, notes and the initial prompt are kept, and are listed in \
            the context column. An archived session stays in Closed, but cannot be reopened: \
            unarchive it first, then restarting its agent is a separate, deliberate step.
            """,
            bundle: .module,
            comment: "Closed is the tab of the sidebar that lists closed sessions."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
  }

  private func dateRow(_ label: LocalizedStringResource, _ date: Date) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(date.formatted(date: .abbreviated, time: .shortened))
    }
  }
}

/// The widths the two columns open at, frozen once so that measuring them cannot move them.
private struct IdealColumnWidths: Equatable {
  let sidebar: Double
  let inspector: Double
}

/// Reports the width of whatever it is placed behind, because SwiftUI never reports back the
/// width a split view was actually dragged to.
private struct WidthReporter: View {
  let report: (Double) -> Void

  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .onChange(of: proxy.size.width, initial: true) { _, width in
          report(Double(width))
        }
    }
  }
}

/// Sort and facets live at the foot of the column rather than above the list: they are consulted
/// rarely, and the rows are what the column is for.
struct SidebarFooter: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        Picker(
          LocalizedStringResource("Sort By", bundle: .module),
          selection: Binding(get: { model.filter.sort }, set: { model.setSort($0) })
        ) {
          ForEach(SessionSort.allCases, id: \.self) { sort in
            Text(sort.label).tag(sort)
          }
        }
        .pickerStyle(.inline)

        if !model.availableProviderIDs.isEmpty {
          Divider()
          Section(LocalizedStringResource("Agent", bundle: .module)) {
            ForEach(model.availableProviderIDs, id: \.self) { providerID in
              Toggle(
                providerID,
                isOn: Binding(
                  get: { model.filter.agentProviderIDs.contains(providerID) },
                  set: { _ in model.toggleProviderFacet(providerID) }
                )
              )
            }
          }
        }

        if !model.availableRepositoryPaths.isEmpty {
          Divider()
          Section(LocalizedStringResource("Folder", bundle: .module)) {
            Button(LocalizedStringResource("Any folder", bundle: .module)) {
              model.setRepositoryFacet(nil)
            }
            ForEach(model.availableRepositoryPaths, id: \.self) { path in
              Button(displayPath(path)) { model.setRepositoryFacet(path) }
            }
          }
        }

        if model.filter.isNarrowing {
          Divider()
          Button(LocalizedStringResource("Clear Filter", bundle: .module)) {
            model.clearNarrowing()
          }
        }
      } label: {
        Label(model.filter.sort.label, systemImage: "arrow.up.arrow.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Spacer(minLength: 0)

      // One list, or one section per working folder. The View menu has it too, on ⌃⌘G. A plain
      // button rather than a toggle styled as one: the help tag of the latter never showed.
      Button {
        model.toggleGrouping()
      } label: {
        Image(systemName: isGrouped ? "folder.fill" : "folder")
          .foregroundStyle(isGrouped ? Color.accentColor : Color.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help(groupingHelp)
      .accessibilityLabel(Text("Group Sessions by Folder", bundle: .module))
      .accessibilityAddTraits(isGrouped ? [.isSelected] : [])
      .accessibilityIdentifier("sidebar-group-toggle")

      if model.filter.isNarrowing {
        Button {
          model.clearNarrowing()
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.borderless)
        .help(Text("Filtering is on. Click to clear it.", bundle: .module))
        .accessibilityLabel(Text("Clear filter", bundle: .module))
      }
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private var isGrouped: Bool {
    model.sidebarMode == .byFolder
  }

  /// Says what a click does, and the shortcut that does the same.
  private var groupingHelp: Text {
    isGrouped
      ? Text("Show the sessions as one list (⌃⌘G)", bundle: .module)
      : Text("Group the sessions by working folder (⌃⌘G)", bundle: .module)
  }
}

/// The three history commands for one session, in the single place that decides whether each of
/// them applies. The menu, the context menu and the accessibility actions all read this.
@MainActor
struct SessionCommands {
  let model: AppModel
  let session: WorkSession

  var canClose: Bool { model.canClose(session) }
  var canArchive: Bool { model.canArchive(session) }
  var canRestore: Bool { model.canRestore(session) }
  var canRestart: Bool { model.canRestart(session) }
  var restartTitle: String { model.restartTitle(for: session) }
  /// Spoken rather than read, so it says what the command will actually do.
  var restartAnnouncement: String { model.expectedRestartMode(for: session) }
  var canSwitchAgent: Bool { model.canSwitchAgent(session) }
  var taskStatus: SessionTaskStatus { session.taskStatus }
  /// The statuses the session can be moved to by hand. Archiving and unarchiving keep their own
  /// commands, which say what they do to the process.
  var movableStatuses: [SessionTaskStatus] {
    session.taskStatus == .archived ? [] : SessionTaskStatus.columns
  }

  func close() { Task { await model.requestClose(session.id) } }
  func requestArchive() { model.requestArchive(session.id) }
  func restore() { Task { await model.restore(session.id) } }
  func restart() { Task { await model.restart(session.id) } }
  func switchAgent() { model.beginAgentSwitch(session.id) }
  func setTaskStatus(_ status: SessionTaskStatus) {
    Task { await model.setTaskStatus(status, for: session.id) }
  }
}

struct SessionCommandButtons: View {
  let commands: SessionCommands

  var body: some View {
    if !commands.movableStatuses.isEmpty {
      Menu {
        ForEach(commands.movableStatuses, id: \.self) { status in
          Toggle(
            status.label,
            isOn: Binding(
              get: { commands.taskStatus == status },
              set: { isOn in if isOn { commands.setTaskStatus(status) } }
            )
          )
        }
      } label: {
        Text(
          "Status", bundle: .module, comment: "The submenu that moves a session between columns.")
      }
      Divider()
    }
    if commands.canRestart {
      Button(commands.restartTitle) { commands.restart() }
    }
    if commands.canSwitchAgent {
      Button(LocalizedStringResource("Switch Agent…", bundle: .module)) { commands.switchAgent() }
    }
    if commands.canClose {
      Button(LocalizedStringResource("Close Session", bundle: .module)) { commands.close() }
    }
    if commands.canArchive {
      Button(LocalizedStringResource("Archive…", bundle: .module)) { commands.requestArchive() }
    }
    if commands.canRestore {
      Button(LocalizedStringResource("Unarchive", bundle: .module)) { commands.restore() }
    }
  }
}

struct SessionRow: View {
  let session: WorkSession
  let icon: NSImage?
  let status: SessionStatusPresentation
  /// The one row the restoration is working on. Said on the row rather than only in the banner,
  /// because the banner names a session the sidebar may have scrolled away from.
  let isRestoring: Bool
  /// Its web view has something unseen: a page its agent opened, or a question (#69).
  let webView: WebViewAttention?
  let shortcutPosition: Int?
  let commands: SessionCommands
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      SessionBadge(appearance: session.appearance, icon: icon)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.name)
          .fontWeight(.medium)
          .lineLimit(1)
        if let agent = session.agent {
          Text(agent.providerID)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // Symbol, words and colour, in that order: the state survives a colour nobody can
        // tell apart, and the identity colour of the session stays free to mean identity.
        Label(status.label, systemImage: status.symbolName)
          .font(.caption)
          // What waits for the user is the one state set apart from the others by more than its
          // colour and its symbol.
          .fontWeight(!isRestoring && status.needsAttention ? .semibold : nil)
          .foregroundStyle(isRestoring ? Color.secondary : tint)
          .modifier(WorkingSymbolEffect(isActive: isWorkingAnimated))
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      switch webView {
      case .waitingForApproval:
        Image(systemName: "hand.raised.fill")
          .foregroundStyle(.orange)
          .help(Text("The agent is waiting for your approval in the web view", bundle: .module))
      case .agentOpenedPage:
        Image(systemName: "globe")
          .font(.caption)
          .foregroundStyle(Color.accentColor)
          .help(Text("The agent opened a page in the web view", bundle: .module))
      case nil:
        EmptyView()
      }
      if let shortcutPosition {
        Text(verbatim: "⌘\(shortcutPosition)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 4)
    .contextMenu {
      SessionCommandButtons(commands: commands)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("session-row")
    .accessibilityLabel(SessionStatusPresentation.accessibilityLabel(for: session, status: status))
    .accessibilityValue(accessibilityValue)
    // The same commands, reachable without a pointer and without the menu bar.
    .accessibilityAction(named: Text(commands.restartAnnouncement)) {
      guard commands.canRestart else { return }
      commands.restart()
    }
    .accessibilityAction(named: Text("Switch Agent", bundle: .module)) {
      guard commands.canSwitchAgent else { return }
      commands.switchAgent()
    }
    .accessibilityAction(named: Text("Close Session", bundle: .module)) {
      guard commands.canClose else { return }
      commands.close()
    }
    .accessibilityAction(named: Text("Archive", bundle: .module)) {
      guard commands.canArchive else { return }
      commands.requestArchive()
    }
    .accessibilityAction(named: Text("Unarchive", bundle: .module)) {
      guard commands.canRestore else { return }
      commands.restore()
    }
    // The swipe's buttons, reachable without it: one action per status the session can go to.
    .accessibilityActions {
      ForEach(commands.movableStatuses.filter { $0 != commands.taskStatus }, id: \.self) {
        status in
        Button {
          commands.setTaskStatus(status)
        } label: {
          Text(status.moveTitle)
        }
      }
    }
  }

  private var accessibilityValue: Text {
    if isRestoring { return Text("Restoring", bundle: .module) }
    switch webView {
    case .waitingForApproval:
      return Text("Waiting for your approval in the web view", bundle: .module)
    case .agentOpenedPage:
      return Text("The agent opened a page", bundle: .module)
    case nil:
      return Text(verbatim: "")
    }
  }

  /// A working agent's symbol moves; with Reduce Motion it stays still, and its shape and its
  /// colour still set it apart.
  private var isWorkingAnimated: Bool {
    !isRestoring && status.isAnimated && !reduceMotion
  }

  private var tint: Color {
    switch status.severity {
    case .normal: return .secondary
    case .active: return .accentColor
    case .attention: return .orange
    case .error: return .red
    }
  }
}

/// The symbol of a working agent turns; before macOS 15, which cannot turn a symbol, it pulses.
private struct WorkingSymbolEffect: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.symbolEffect(.rotate, options: .repeating, isActive: isActive)
    } else {
      content.symbolEffect(.pulse, options: .repeating, isActive: isActive)
    }
  }
}

/// Holds the window a view is drawn in, without keeping it alive.
private final class HostWindow {
  weak var window: NSWindow?
}

/// Hands the window a view is drawn in to `HostWindow`, once it has one.
private struct HostWindowReader: NSViewRepresentable {
  let host: HostWindow

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in host.window = view?.window }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let window = nsView.window { host.window = window }
  }
}

extension View {
  /// Says `text` to VoiceOver when the view appears.
  func announcedOnAppear(_ text: String) -> some View {
    onAppear { Announcer.announce(text) }
  }
}

/// Over the conversation of an archived session: what it is, and the way back.
private struct ArchivedConversationBar: View {
  let unarchive: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "archivebox.fill")
        .foregroundStyle(.secondary)
      Text(
        "This session is archived: nothing was deleted, and it cannot be reopened.",
        bundle: .module
      )
      .font(.callout)
      Spacer(minLength: 8)
      Button(LocalizedStringResource("Unarchive", bundle: .module), action: unarchive)
        .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
  }
}

/// What makes the conversation of a session worth readying again.
private struct ConversationShowKey: Hashable {
  let session: SessionID
  let conversations: [SessionAgentConfiguration]
  let presentation: SessionPresentation

  init(session: WorkSession, presentation: SessionPresentation) {
    self.session = session.id
    conversations = session.conversationAgents
    self.presentation = presentation
  }
}

/// Conversation or Terminal, for the session on screen (#38).
private struct PresentationPicker: View {
  @Binding var selection: SessionPresentation

  var body: some View {
    Picker(selection: $selection) {
      Text("Conversation", bundle: .module).tag(SessionPresentation.conversation)
      Text("Terminal", bundle: .module, comment: "The raw terminal of a session, as a view.")
        .tag(SessionPresentation.terminal)
    } label: {
      Text("Show the session as", bundle: .module)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .help(Text("Switch between the conversation and the terminal (⌥⌘T)", bundle: .module))
  }
}
