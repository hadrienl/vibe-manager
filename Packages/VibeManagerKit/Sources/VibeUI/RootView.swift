import Foundation
import SwiftUI
import UniformTypeIdentifiers
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
  /// The "Don't ask again" box of the close and archive confirmations, unticked each time one opens.
  @State private var suppressesCloseConfirmation = false
  /// The window this view is drawn in: the only one whose visibility says whether its sessions
  /// are in front of the user.
  @State private var hostWindow = HostWindow()
  /// Where the detail column lies: the room of the window's title depends on it (#159).
  @State private var titleRoom = WindowTitleRoom()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openSettings) private var openSettings
  /// The window's: where ⌘Z finds a discarded draft (#293).
  @Environment(\.undoManager) private var undoManager
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    let _ = BodyCounter.tick(.rootView)
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
    // The application's zoom (#229), for every terminal of the window: the session's, the drawer's
    // and the copies shown in the conversation.
    .environment(\.terminalFontSize, model.conversations.appearance.textSize.terminalPointSize)
    // The window's title (#159), in every state: the Window menu, Mission Control and ⌘` read it.
    // From macOS 26 the toolbar draws it itself, the application's name and the session's in two
    // styles (#256).
    .navigationTitle(model.windowTitle.full)
    .removingSystemDrawnTitle()
    // Open Quickly, over the whole window (#37).
    .overlay {
      if case .loaded = model.state, model.quickOpen.isPresented {
        QuickOpenPanel(model: model)
      }
    }
    // A window closed with the palette open does not reopen on it.
    .onDisappear { model.quickOpen.dismiss(restoringFocus: false) }
    // Narrower than the two sidebars plus a usable terminal on purpose: below the layout
    // thresholds the columns fold, and the window is still worth opening.
    .frame(minWidth: 640, minHeight: 480)
    .task {
      await model.load()
      // Launched behind another application — at login, with `open -g` — it never resigned: it
      // must not believe it is in front, or the floating panel of #41 would wait for nothing.
      if !NSApp.isActive { model.applicationWillResignActive() }
      idealWidths = IdealColumnWidths(
        sidebar: model.layout.intent.sidebarWidth,
        inspector: model.layout.intent.inspectorWidth
      )
    }
    // Session › Attach Files… (⌘O): the keyboard's way to a drop (#42). Folders too, as from the
    // Finder.
    .fileImporter(
      isPresented: Binding(
        get: { model.isChoosingFilesToAttach }, set: { model.isChoosingFilesToAttach = $0 }),
      allowedContentTypes: [.item, .folder], allowsMultipleSelection: true
    ) { result in
      guard case .success(let files) = result else { return }
      Task { await model.attachChosenFiles(files) }
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
    .background(FullScreenTitlebarRepairReader(columns: model.layout.columns))
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
  ///
  /// `AppModel.isPresentingSheet` asks the same questions: a new one goes in both.
  private var presentedSheet: RootSheet? {
    if model.permissions?.isPresentingStep == true { return .fullDiskAccess }
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
        if let failure = model.actionFailure {
          // The store's banner, without what belongs to the store: there is no backup to offer
          // over an archive that failed, and Try Again runs the action, not a reload.
          RefreshFailureBanner(
            failure: AppModel.RefreshFailure(message: failure.message, canRestoreBackup: false),
            retry: { Task { await model.retryActionFailure() } },
            restore: {},
            export: nil,
            dismiss: { model.dismissActionFailure() }
          )
          Divider()
        }
        if !model.sessionsStoppedWithHost.isEmpty {
          HostStoppedBanner(
            count: model.sessionsStoppedWithHost.count,
            restartAll: { Task { await model.restartSessionsStoppedWithHost() } },
            dismiss: { model.setAsideSessionsStoppedWithHost() }
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
        if let report = model.batchReport {
          BatchReportBanner(report: report, dismiss: { model.dismissBatchReport() })
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
        if let permissions = model.permissions, permissions.showsRestartNotice,
          case .pendingRestart(let runner, let running) = permissions.situation
        {
          FullDiskAccessRestartBanner(
            permissions: permissions, runner: runner, runningAgents: running)
          Divider()
        }
        detail
          // The whole area, whatever it shows: an overlay is only as large as what it covers, and
          // over the small "No session yet" the draft was squeezed to its composer (#177).
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // Under the draft, neither Tab nor VoiceOver reaches the session's web view or drawer.
          .disabled(model.isPresentingNewSession)
          .accessibilityHidden(model.isPresentingNewSession)
          .overlay {
            if let creation = model.shownCreation {
              SessionCreationPlaceholder(creation: creation)
            }
          }
          // Over the session selected rather than in its place: every terminal stays mounted
          // underneath, and leaving the draft finds the session exactly as it was (#177).
          .overlay {
            if model.isPresentingNewSession, let draft = model.newSessionModel {
              NewSessionDraftView(
                model: draft,
                focusRequest: model.newSessionFocusRequest,
                submitted: { launching in model.submitNewSession(launching: launching) },
                discarded: { model.discardNewSessionDraft(undoManager: undoManager) },
                chooseFiles: { model.beginAttachingFiles() },
                manageTemplates: {
                  model.settingsTab = .templates
                  openSettings()
                },
                themes: model.conversations.themes,
                conversationAppearance: model.conversations.appearance
              )
              // One view per draft: another draft brought on screen starts with its own folds,
              // popover and caret, not the ones left by the previous.
              .id(draft.draftID)
              // The list under `/` wears the conversations' colours, as in a conversation (#219).
              .environment(\.conversationTheme, conversationTheme)
            }
          }
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: { frame in
        titleRoom.detailLeading = frame.minX
        titleRoom.detailWidth = frame.width
      }
      .restartNowConfirmation(
        permissions: model.permissions, origin: .workspace, sessionName: model.sessionName(for:)
      )
      // No shortcut here: ⌘N belongs to the New Session menu command, which owns it for the
      // whole application. Repeating it bound the same key twice, under two conditions.
      .toolbar {
        // With the sidebar folded, its palette is reached from here (#40).
        ToolbarItem(placement: .navigation) {
          if !model.layout.columns.isSidebarVisible, model.pendingRequestCount > 0 {
            RequestPaletteToolbarButton(model: model)
          }
        }
        // After the palette's button: the title's room is measured from where it starts (#159).
        if WindowTitleToolbarItem.isDrawn {
          WindowTitleToolbarItem(title: model.windowTitle, room: titleRoom)
        }
        // Where the work on the session on screen stands, and a way to change it (#80).
        ToolbarItem(placement: .primaryAction) {
          if !model.isPresentingNewSession, let session = model.selectedSession,
            session.taskStatus != .archived
          {
            TaskStatusMenu(commands: SessionCommands(model: model, session: session))
          }
        }
        ToolbarItem(placement: .principal) {
          if !model.isPresentingNewSession, let session = model.selectedSession,
            model.conversations.canShowConversation(session)
          {
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
          if model.layout.columns.browser == .alternating, !model.isPresentingNewSession {
            ToolbarItem(placement: .principal) {
              Picker(
                selection: Binding(
                  get: { model.layout.showsBrowserWhenAlternating },
                  set: { showsBrowser in
                    model.layout.setShowsBrowserWhenAlternating(showsBrowser)
                    if !showsBrowser { model.focusSession() }
                  })
              ) {
                // “Session”, not “Terminal”: beside it the session's own picker already says
                // Conversation or Terminal, and one word must not name two things (#247).
                Text(
                  "Session", bundle: .module,
                  comment: "Of the two views taking turns in a narrow window: the session's own."
                )
                .tag(false)
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
          if !model.isPresentingNewSession, let session = model.selectedSession {
            VStack(spacing: 0) {
              SessionIdentityHeader(model: model, session: session)
              Divider()
              inspector(for: session)
            }
            // ⌘Z undoes a rename, a change of icon (#183) or an archive (#242) here too; the notes
            // and the name being typed undo their own typing.
            .onCommand(Selector(("undo:")), perform: model.sidebarUndoAction(redo: false))
            .onCommand(Selector(("redo:")), perform: model.sidebarUndoAction(redo: true))
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
    // A name or an icon that could not be written (#183), wherever it was edited: the inspector
    // is where it is edited with the sidebar hidden.
    .alert(
      Text("The session could not be changed.", bundle: .module),
      isPresented: Binding(
        get: { model.identityFailure != nil },
        set: { if !$0 { model.dismissIdentityFailure() } })
    ) {
      Button(LocalizedStringResource("OK", bundle: .module)) { model.dismissIdentityFailure() }
    } message: {
      Text(verbatim: model.identityFailure ?? "")
    }
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
    } message: { session in
      Text(closeConfirmationMessage(for: session))
    }
    // Closing several sessions asks #51's question once, with its "Don't ask again" (#77).
    .confirmationDialog(
      Text(verbatim: model.pendingBatch?.title ?? ""),
      isPresented: batchBinding(close: true),
      titleVisibility: .visible,
      presenting: model.pendingBatch
    ) { confirmation in
      Button(confirmation.confirmTitle) {
        let askAgain = !suppressesCloseConfirmation
        Task { await model.confirmBatch(confirmation, askAgain: askAgain) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelBatch()
      }
    } message: { confirmation in
      Text(verbatim: confirmation.message)
    }
    // Asked only when archiving stops work in progress (#115), with the close question's "Don't
    // ask again": the two share one setting. Cancel is the default button: the key that opened
    // this must not also answer it.
    .archiveConfirmation(
      model: model, isOffered: model.pendingArchive.map(model.archiveOffersDontAskAgain) == true,
      suppressesConfirmation: $suppressesCloseConfirmation,
      message: archiveConfirmationMessage(for:)
    )
    // Before the side terminal's dialog and the other batch one in the chain: the toggle reaches
    // every dialog it wraps, and a question has a "Don't ask again" only when it is #51's.
    .dialogSuppressionToggle(
      Text("Don’t ask again", bundle: .module), isSuppressed: $suppressesCloseConfirmation
    )
    .onChange(of: model.pendingClose?.id) { _, id in
      if id != nil { suppressesCloseConfirmation = false }
    }
    .onChange(of: model.pendingBatch?.id) { _, id in
      if id != nil { suppressesCloseConfirmation = false }
    }
    .onChange(of: model.pendingArchive?.id) { _, id in
      if id != nil { suppressesCloseConfirmation = false }
    }
    // The same question when only an agent in the middle of a turn asks it (#242): after the
    // suppression toggle, since "Don't ask again" would change nothing — it is always asked.
    .archiveConfirmation(
      model: model, isOffered: model.pendingArchive.map(model.archiveOffersDontAskAgain) == false,
      suppressesConfirmation: .constant(false), message: archiveConfirmationMessage(for:)
    )
    // ⌃⌘→ or ⌃⌘← that would restart a closed session's agent (#240): a key pressed by mistake
    // must not start one. After the suppression toggle: this question has no "Don't ask again".
    .confirmationDialog(
      model.pendingStatusRestart.map {
        Text("Restart “\($0.session.name)”?", bundle: .module, comment: "A session's name.")
      } ?? Text("Restart this session?", bundle: .module),
      isPresented: Binding(
        get: { model.pendingStatusRestart != nil },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelStatusRestart()
        }
      ),
      titleVisibility: .visible,
      presenting: model.pendingStatusRestart
    ) { restart in
      Button(LocalizedStringResource("Move and Restart", bundle: .module)) {
        Task { await model.confirmStatusRestart(restart) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelStatusRestart()
      }
    } message: { restart in
      Text(
        "Moving it to \(String(localized: restart.status.label)) starts its agent again.",
        bundle: .module, comment: "A task status.")
    }
    // A side terminal is closed at once, unless a command runs in its foreground (#43). After
    // the suppression toggle: this question has no "Don't ask again" (#115).
    .confirmationDialog(
      Text("Close this terminal?", bundle: .module),
      isPresented: Binding(
        get: { model.pendingTerminalClose != nil },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelCloseDrawerTerminal()
        }
      ),
      titleVisibility: .visible,
      presenting: model.pendingTerminalClose
    ) { pending in
      Button(LocalizedStringResource("Close Terminal", bundle: .module), role: .destructive) {
        model.confirmCloseDrawerTerminal(pending)
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelCloseDrawerTerminal()
      }
    } message: { pending in
      Text(
        "“\(pending.command)” is still running in this terminal and will be stopped.",
        bundle: .module, comment: "The argument is the command running in a side terminal.")
    }
    // Every other command on several sessions: one question, Cancel by default (#77).
    .confirmationDialog(
      Text(verbatim: model.pendingBatch?.title ?? ""),
      isPresented: batchBinding(close: false),
      titleVisibility: .visible,
      presenting: model.pendingBatch
    ) { confirmation in
      // Many agents to restart (#192): moving without restarting comes first, as the default.
      if let withoutRestartTitle = confirmation.withoutRestartTitle {
        Button(withoutRestartTitle) {
          Task { await model.confirmBatch(confirmation, restarting: false) }
        }
        .keyboardShortcut(.defaultAction)
      }
      Button(confirmation.confirmTitle) {
        Task { await model.confirmBatch(confirmation) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelBatch()
      }
    } message: { confirmation in
      Text(verbatim: confirmation.message)
    }
  }

  /// One binding per dialog: the close question carries a toggle the others must not show.
  private func batchBinding(close: Bool) -> Binding<Bool> {
    Binding(
      get: { model.pendingBatch.map { $0.isClose == close } ?? false },
      set: { isPresented in
        guard !isPresented else { return }
        model.cancelBatch()
      }
    )
  }

  /// The sections of the inspector, under the session's header.
  private func inspector(for session: WorkSession) -> some View {
    SessionContextInspector(
      session: session,
      resolution: model.resolution(forID: session.id),
      branchReport: model.branchReport(for: session.id),
      branchReportCheckedAt: { model.branchReportCheckedAt(for: session.id) },
      repositoryStatuses: model.repositoryStatuses,
      sessionNames: Dictionary(
        model.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
      refreshBranches: model.reportsBranches
        ? { Task { await model.refreshBranchReport() } } : nil,
      git: model.gitInspector,
      layout: model.layout,
      openPrivacySettings: model.permissions.map { permissions in
        { permissions.openSystemSettings() }
      },
      agentNames: model.agentNames,
      switchAgent: model.canSwitchAgent(session)
        ? { model.beginAgentSwitch(session.id) } : nil,
      notes: model.notes,
      ticketTitles: model.ticketTitles,
      leaveNotes: { model.focusSession() },
      usage: model.usage,
      journal: model.journal
    )
  }

  private func closeConfirmationMessage(for session: WorkSession) -> String {
    let drawer = drawerCommandsSentence(for: session)
    // Only side terminals at work (#115): the agent has nothing left to stop.
    // An agent still starting is at work too: the launcher counts it, as the question's rule does.
    if let drawer, model.launcher?.isRunning(session.id) != true { return drawer }
    let consequence = String(
      localized: "The agent will be stopped. The session can be restarted later.", bundle: .module)
    guard let drawer else { return consequence }
    return consequence + " " + drawer
  }

  /// The commands a close or an archive stops in the session's side terminals (#43), named.
  private func drawerCommandsSentence(for session: WorkSession) -> String? {
    let commands = model.runningDrawerCommands(of: session.id)
    guard !commands.isEmpty else { return nil }
    let list = commands.map { "“\($0)”" }.formatted(.list(type: .and))
    return String(
      localized: "What runs in its side terminals will be stopped: \(list).", bundle: .module,
      comment: "The argument lists the commands running in the session's side terminals.")
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
    let drawer = drawerCommandsSentence(for: session).map { " " + $0 } ?? ""
    guard isRunning else { return consequence + drawer }
    return String(localized: "Its running agent will be stopped.", bundle: .module) + " "
      + consequence + drawer
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
        sessionWithDrawer(for: session)
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
  /// About eight lines and the status bar: the drawer of side terminals gives way before the
  /// session's own terminal gets any shorter.
  private static let sessionMinimumHeight: Double = 160

  /// The session's content, and its drawer of side terminals under it, the whole width (#43).
  ///
  /// One structure whatever the session, the drawer alone being conditional: the terminal stack
  /// holds every session's terminal, and a branch that swapped it for another would remount them
  /// all — a replayed history and a lost scroll position for each — at every change between a
  /// session that has a drawer and one that has not.
  private func sessionWithDrawer(for session: WorkSession) -> some View {
    let drawer = model.canUseDrawer(session) ? model.terminals?.drawer(for: session.id) : nil
    return GeometryReader { proxy in
      let total = Double(proxy.size.height)
      let lower = SessionTerminalsDocument.heightRange.lowerBound
      let upper = max(lower, min(total * 0.7, total - Self.sessionMinimumHeight))
      VStack(spacing: 0) {
        sessionContent(for: session)
        if let drawer, drawer.isVisible, !drawer.terminals.isEmpty {
          let height = min(max(drawer.height, lower), upper)
          SplitHandle(
            axis: .vertical,
            length: height, range: lower...upper,
            label: Text("Divider between the session and its side terminals", bundle: .module),
            value: Text(
              "\(Int(height)) points tall", bundle: .module,
              comment:
                "The height of the drawer of side terminals, read by VoiceOver on its divider."
            ),
            sizesPaneBelow: true,
            onChange: { drawer.setHeight($0) })
          TerminalDrawerView(model: model, drawer: drawer, sessionName: session.name)
            .frame(height: height)
            .id(session.id)
        }
      }
    }
    // Asked again when the session becomes active: a drawer left open comes back with it.
    .task(id: DrawerPreparationKey(session: session.id, isActive: drawer != nil)) {
      guard drawer != nil else { return }
      await model.terminals?.prepare(session.id)
    }
  }

  /// The terminal, and the web view beside it or in turns with it (#69).
  ///
  /// The terminal is never taken out of the hierarchy, nor narrowed to nothing: when the web view
  /// takes its place, it is drawn over it. A terminal resized to zero columns would tell its agent
  /// so, and every full-screen program in it would redraw for a window it does not have.
  ///
  /// One structure whatever the web view does, the web view alone being conditional (#149): the
  /// terminal stack holds every session's terminal, and a branch per arrangement made showing or
  /// hiding the web view a different view to SwiftUI — every terminal torn down and remade, each
  /// replaying its whole history on the main thread, at each click of the toolbar's button.
  private func sessionContent(for session: WorkSession) -> some View {
    let workspace = session.status == .archived ? nil : model.browser
    let placement: BrowserPlacement = workspace == nil ? .hidden : model.layout.columns.browser
    return BrowserSplit(
      layout: model.layout, sessionID: session.id, placement: placement,
      canSlide: workspace != nil, terminalMinimum: Self.terminalMinimumWidth
    ) {
      terminalStack(for: session)
        .overlay {
          if let workspace, placement == .alternating, model.layout.showsBrowserWhenAlternating {
            BrowserPanel(
              model: model, workspace: workspace, browser: workspace.browser(for: session.id))
          }
        }
    } trailing: {
      if let workspace {
        BrowserPanel(
          model: model, workspace: workspace, browser: workspace.browser(for: session.id))
      }
    }
  }

  /// The settings' theme for the system's appearance of the moment — or the one on trial in the
  /// settings (#118): what a new session's draft is drawn with. Each conversation resolves its
  /// own (#274).
  private var conversationTheme: ConversationTheme {
    model.conversations.themes.displayed(
      ConversationFonts.installedOnly(model.conversations.appearance),
      isDark: colorScheme == .dark, increasedContrast: colorSchemeContrast == .increased)
  }

  @ViewBuilder
  private func terminalStack(for session: WorkSession) -> some View {
    let presentation = model.presentation(of: session)
    // Under the placeholder of a session being made, or a new session's draft (#177), nothing
    // keeps the keyboard: typed into, the session left would take what was meant for the new one.
    let isCovered = model.shownCreation != nil || model.isPresentingNewSession
    ZStack {
      // Each session's slot reads what changes while its agent works — its terminal's state, its
      // activity — in its own `body`: a transition in one session evaluates that slot again, not
      // the window (#254). Only the sessions with a pane are walked, never the archived ones.
      ForEach(model.paneSessionIDs, id: \.self) { id in
        SessionTerminalSlot(model: model, id: id, shownID: session.id, isCovered: isCovered)
      }

      // Mounted like the terminals, so that going back and forth keeps each one's place. Only
      // the few sessions last shown in conversation keep one.
      // Each with its own theme (#274), resolved for the window's appearance: the conversation
      // forces its own scheme on what it draws, not on this.
      ForEach(model.conversations.mountedSessionIDs, id: \.self) { id in
        SessionConversationSlot(
          model: model, id: id, shownID: session.id, isCovered: isCovered,
          isDark: colorScheme == .dark, increasedContrast: colorSchemeContrast == .increased)
      }

      // An archived session has no pane by construction — archiving released it — so its own
      // card is what the column shows, rather than the "no terminal" message of a session
      // that simply has not been started.
      if presentation == .conversation {
        EmptyView()
      } else if session.status == .archived {
        let appearance = model.displayedAppearance(of: session)
        ArchivedSessionDetail(
          session: session, agentNames: model.agentNames, appearance: appearance,
          icon: model.icons.image(for: appearance.iconID)
        ) {
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
    // One place to drop files on, whichever of the two is on screen (#42).
    .modifier(SessionDropZone(model: model, sessionID: session.id))
    // At the top: at the foot it would cover the line the paths were just typed on, or the
    // composer.
    .overlay(alignment: .top) {
      if let notice = model.dropNotice, notice.sessionID == session.id {
        DropNoticeBar(
          notice: notice,
          allowFullDiskAccess: {
            model.dismissDropNotice()
            model.settingsTab = .privacy
            openSettings()
          },
          dismiss: { model.dismissDropNotice() }
        )
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

/// What the drawer of the session on screen is prepared for: that session, once it is active.
private struct DrawerPreparationKey: Hashable {
  let session: SessionID
  let isActive: Bool
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

/// The terminal host stopped, and took these sessions' agents with it (#237): the cause, once,
/// and the one thing to do about it. It goes away as they are restarted, or when dismissed.
private struct HostStoppedBanner: View {
  let count: Int
  let restartAll: () -> Void
  let dismiss: () -> Void

  private var message: String {
    String(
      localized: "The terminal host stopped: \(count) sessions were interrupted.",
      bundle: .module, comment: "How many sessions lost their agent.")
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .lineLimit(2)
      Spacer(minLength: 8)
      Button(LocalizedStringResource("Restart All", bundle: .module), action: restartAll)
        .controlSize(.small)
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text("Dismiss", bundle: .module))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
    .announcedOnAppear(message)
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

/// Full Disk Access granted, and not yet to the agents: the process that runs them started before
/// (#76). It offers the two ways through, and neither stops an agent unnamed.
private struct FullDiskAccessRestartBanner: View {
  let permissions: PermissionsModel
  let runner: FullDiskAccessSituation.PendingRunner
  let runningAgents: Int

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.open.rotation")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Full Disk Access is granted, but not yet to your agents.", bundle: .module)
          .font(.callout)
        PendingRestartExplanation(runner: runner, runningAgents: runningAgents)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if runner == .host, runningAgents > 0 {
        RestartHostButtons(permissions: permissions, origin: .workspace)
      }
      Button {
        permissions.dismissRestartNotice()
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
        localized: "Full Disk Access is granted, but not yet to your agents.", bundle: .module))
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

/// What a command on several sessions could not do (#77).
private struct BatchReportBanner: View {
  let report: SessionBatchReport
  let dismiss: () -> Void

  @State private var isShowingDetails = true

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: report.message)
          .font(.callout)
        if isShowingDetails {
          ForEach(report.lines) { line in
            VStack(alignment: .leading, spacing: 1) {
              Text(verbatim: line.text)
                .font(.caption)
              if let suggestion = line.suggestion {
                Text(verbatim: suggestion)
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
    .accessibilityIdentifier("batch-report")
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
  let agentNames: [String: String]
  /// Its badge as drawn: the one previewed while its icon is being changed (#183).
  let appearance: SessionAppearance
  let icon: NSImage?
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
            SessionBadge(appearance: appearance, icon: icon)
            VStack(alignment: .leading, spacing: 2) {
              Text(session.name)
                .font(.title3)
                .fontWeight(.semibold)
              if let agent = session.agent {
                Text(AgentNaming.label(agent, names: agentNames))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .help(Text(verbatim: agent.providerID))
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
                AgentNaming.name(of: providerID, names: model.agentNames),
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
      // Where the order arranged by hand is found, for whoever looks for how to drag a row (#44).
      .help(model.reorderUnavailableReason.map { Text($0) } ?? Text(model.filter.sort.label))

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
  /// Renaming and changing the badge (#183), in any state, archived included.
  var canEditIdentity: Bool { model.canEditIdentity(of: session.id) }
  var isRenaming: Bool {
    model.renaming == SessionIdentityEditing(sessionID: session.id, place: .sidebar)
  }
  /// Whether the order can be arranged at all: the Manual sort, nothing narrowing the list (#44).
  var canReorder: Bool { model.canReorder }
  var canMoveUp: Bool { model.canMove(session.id, by: -1) }
  var canMoveDown: Bool { model.canMove(session.id, by: 1) }
  var taskStatus: SessionTaskStatus { session.taskStatus }
  /// The statuses the session can be moved to by hand. Archiving and unarchiving keep their own
  /// commands, which say what they do to the process.
  var movableStatuses: [SessionTaskStatus] {
    session.taskStatus == .archived ? [] : SessionTaskStatus.columns
  }

  func close() { Task { await model.requestClose(session.id) } }
  func requestArchive() { Task { await model.requestArchive(session.id) } }
  /// Whether Archive asks first (#115), which its name then says with an ellipsis.
  var archiveAsks: Bool { model.archiveAsks(session) }
  func restore() { Task { await model.restore(session.id) } }
  func restart() { Task { await model.restart(session.id) } }
  func switchAgent() { model.beginAgentSwitch(session.id) }
  func rename() { model.beginRename(session.id, in: .sidebar) }
  func changeIcon() { model.beginAppearanceEditing(session.id, in: .sidebar) }
  func changeTheme() { model.beginThemeEditing(session.id, in: .sidebar) }
  func moveUp() { Task { await model.move(session.id, by: -1) } }
  func moveDown() { Task { await model.move(session.id, by: 1) } }
  func setTaskStatus(_ status: SessionTaskStatus) {
    Task { await model.setTaskStatus(status, for: session.id) }
  }
}

struct SessionCommandButtons: View {
  let commands: SessionCommands

  var body: some View {
    if commands.canEditIdentity {
      Button(LocalizedStringResource("Rename", bundle: .module, comment: "Renames a session.")) {
        commands.rename()
      }
      Button(LocalizedStringResource("Change Icon…", bundle: .module)) { commands.changeIcon() }
      Button(LocalizedStringResource("Change Conversation Theme…", bundle: .module)) {
        commands.changeTheme()
      }
      Divider()
    }
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
    // Only where the order can be arranged: in any other sort they would always be greyed out.
    if commands.canReorder {
      Button(LocalizedStringResource("Move Up", bundle: .module)) { commands.moveUp() }
        .disabled(!commands.canMoveUp)
      Button(LocalizedStringResource("Move Down", bundle: .module)) { commands.moveDown() }
        .disabled(!commands.canMoveDown)
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
      Button(
        commands.archiveAsks
          ? LocalizedStringResource("Archive…", bundle: .module)
          : LocalizedStringResource("Archive", bundle: .module)
      ) { commands.requestArchive() }
    }
    if commands.canRestore {
      Button(LocalizedStringResource("Unarchive", bundle: .module)) { commands.restore() }
    }
  }
}

/// Where the badges of the sidebar's rows end, in the window (#183).
struct SessionBadgeEdgeKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = value ?? nextValue()
  }
}

struct SessionRow: View {
  let session: WorkSession
  /// The badge drawn: the session's, or the one previewed in its Change Icon popover (#183).
  let appearance: SessionAppearance
  let icon: NSImage?
  let shortcutPosition: Int?
  let commands: SessionCommands
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let _ = BodyCounter.tick(.sessionRow)
    HStack(spacing: 10) {
      SessionBadge(appearance: appearance, icon: icon)
        .background {
          GeometryReader { proxy in
            Color.clear.preference(
              key: SessionBadgeEdgeKey.self, value: proxy.frame(in: .global).maxX)
          }
        }
        .sessionAppearancePopover(model: commands.model, sessionID: session.id, place: .sidebar)
      VStack(alignment: .leading, spacing: 2) {
        if commands.isRenaming {
          SessionNameField(
            model: commands.model, session: session,
            font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium))
        } else {
          Text(session.name)
            .fontWeight(.medium)
            .lineLimit(1)
        }
        if let agent = session.agent {
          Text(AgentNaming.name(of: agent.providerID, names: commands.model.agentNames))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Text(verbatim: agent.providerID))
        }
        // Symbol, words and colour, in that order: the state survives a colour nobody can
        // tell apart, and the identity colour of the session stays free to mean identity.
        Label {
          Text(status.label)
        } icon: {
          Image(systemName: status.symbolName)
            .opacity(isWorkingAnimated ? 0 : 1)
            .overlay {
              if isWorkingAnimated { WorkingSpinner() }
            }
        }
        .font(.caption)
        // What waits for the user is the one state set apart from the others by more than its
        // colour and its symbol.
        .fontWeight(!isRestoring && status.needsAttention ? .semibold : nil)
        // The exit code or the signal, for whoever wants it, behind words that say what happened.
        .help(status.detail ?? "")
        .foregroundStyle(isRestoring ? Color.secondary : tint)
        .lineLimit(1)
      }
      .sessionThemePopover(model: commands.model, sessionID: session.id, place: .sidebar)
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
    // The menu is the list's (#77): it knows whether the click landed in a selection of several.
    // Its name field, while it is renamed, is reached on its own.
    .accessibilityElement(children: commands.isRenaming ? .contain : .combine)
    .accessibilityIdentifier("session-row")
    .accessibilityLabel(
      SessionStatusPresentation.accessibilityLabel(
        for: session, status: status, agentNames: commands.model.agentNames)
    )
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
    .accessibilityAction(named: Text("Rename", bundle: .module, comment: "Renames a session.")) {
      guard commands.canEditIdentity else { return }
      commands.rename()
    }
    .accessibilityAction(named: Text("Change Icon", bundle: .module)) {
      guard commands.canEditIdentity else { return }
      commands.changeIcon()
    }
    .accessibilityAction(named: Text("Change Conversation Theme", bundle: .module)) {
      guard commands.canEditIdentity else { return }
      commands.changeTheme()
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
    // The drag that reorders, reachable without it (#44).
    .accessibilityActions {
      if commands.canMoveUp {
        Button {
          commands.moveUp()
        } label: {
          Text("Move Up", bundle: .module)
        }
      }
      if commands.canMoveDown {
        Button {
          commands.moveDown()
        } label: {
          Text("Move Down", bundle: .module)
        }
      }
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

  // Read by the row itself rather than handed to it by the list (#254): what an agent does wakes
  // its own row, not the whole list.
  private var status: SessionStatusPresentation {
    commands.model.statusPresentation(for: session)
  }

  /// The one row the restoration is working on. Said on the row rather than only in the banner,
  /// because the banner names a session the sidebar may have scrolled away from.
  private var isRestoring: Bool {
    commands.model.isRestoring(session.id)
  }

  /// Its web view has something unseen: a page its agent opened, or a question (#69).
  private var webView: WebViewAttention? {
    commands.model.webViewAttention(for: session.id)
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

  /// A working agent's symbol gives way to a spinner; with Reduce Motion the symbol stays, and its
  /// shape and its colour still set it apart.
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

/// What turns in place of a working agent's symbol, in the space that symbol takes.
///
/// A native spinner, not a repeating symbol effect: SwiftUI drives a symbol effect frame by frame,
/// and in a sidebar row every frame resized the row's hosting view and laid the whole window out
/// again — most of a core for as long as an agent worked. AppKit animates this indicator on its
/// own, outside the view graph.
private struct WorkingSpinner: View {
  var body: some View {
    ProgressView()
      .controlSize(.mini)
      .accessibilityHidden(true)
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

extension View {
  /// The conversation's links follow the session's rule (#186): its text views ask for them, and
  /// the links SwiftUI draws — a table's cells, a tool's address — go through `openURL`.
  func conversationLinks(of id: SessionID, in model: AppModel) -> some View {
    let links = ConversationLinks(
      open: { [weak model] url, gesture in model?.openLink(url, from: id, gesture: gesture) },
      hasWebView: { [weak model] in model?.hasWebView(id) ?? false })
    return
      self
      .environment(\.conversationLinks, links)
      .environment(
        \.openURL,
        OpenURLAction { url in
          links.click(url)
          return .handled
        })
  }
}

/// "Terminal — <session> — <what its agent is doing>".
@MainActor
private func terminalTitle(
  for session: WorkSession, pane: TerminalPaneModel, in model: AppModel
) -> String {
  let status = SessionStatusPresentation.make(
    session: session,
    paneStatus: pane.status,
    resolution: model.resolution(forID: session.id),
    wasStoppedOnPurpose: pane.wasStoppedOnPurpose,
    activity: model.activity(for: session.id),
    launchFailed: pane.failure != nil
  )
  return String(
    localized: "Terminal — \(session.name) — \(String(localized: status.label))",
    bundle: .module,
    comment: "What VoiceOver calls a terminal: the session's name, then its state.")
}

/// Restart, at the foot of a session's terminal: the session's own, which resumes its
/// conversation — never the pane's process run again as it was launched (#138).
@MainActor
private func sessionRestart(for id: SessionID, in model: AppModel) -> () -> Void {
  { Task { await model.restart(id) } }
}

/// The status bar's button for a session's agent: Close Session, which asks first when the agent
/// is at work, as ⇧⌘W does (#238).
@MainActor
private func sessionClose(for id: SessionID, in model: AppModel) -> () -> Void {
  { Task { await model.requestClose(id) } }
}

/// One session's terminal in the window's stack, shown or kept behind the one shown (#254).
///
/// A view of its own so that what changes while an agent works — the terminal's state, the
/// agent's activity in its accessibility title — is read here, and wakes this slot alone.
private struct SessionTerminalSlot: View {
  let model: AppModel
  let id: SessionID
  /// The session the column shows.
  let shownID: SessionID
  /// Under the placeholder of a session being made, or a new session's draft (#177).
  let isCovered: Bool

  var body: some View {
    let _ = BodyCounter.tick(.sessionTerminalSlot)
    if let pane = model.pane(for: id), let session = model.session(withID: id) {
      let isActive =
        !isCovered && id == shownID && model.presentation(of: session) == .terminal
      // Started by the launcher, so switching sessions never restarts an agent.
      TerminalPaneView(
        model: pane, autoStart: false, isActive: isActive,
        accessibilityTitle: terminalTitle(for: session, pane: pane, in: model),
        statusAccessory: model.terminals == nil
          ? nil : DrawerStatusButton(model: model, session: session),
        claimsKeyboardOnActivation: model.terminalClaimsKeyboardOnActivation,
        restart: sessionRestart(for: id, in: model), canRestart: model.canRestart(session),
        close: sessionClose(for: id, in: model)
      )
      .id(id)
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
    }
  }
}

/// One session's conversation in the window's stack, shown or kept behind the one shown.
private struct SessionConversationSlot: View {
  let model: AppModel
  let id: SessionID
  let shownID: SessionID
  let isCovered: Bool
  let isDark: Bool
  let increasedContrast: Bool
  @Environment(\.paneWidthHold) private var widthHold

  var body: some View {
    if let conversation = model.conversations.existingModel(for: id),
      let listed = model.session(withID: id)
    {
      // The theme of the session's own (#274), or the settings' — or the one on trial in them
      // (#118).
      let theme = model.conversations.themes.displayed(
        ConversationFonts.installedOnly(model.conversations.appearance),
        session: model.displayedConversationTheme(of: listed), isDark: isDark,
        increasedContrast: increasedContrast)
      let isActive =
        !isCovered && id == shownID && model.presentation(of: listed) == .conversation
      VStack(spacing: 0) {
        ConversationView(
          model: conversation, theme: theme,
          appearance: model.conversations.appearance, isActive: isActive,
          claimsKeyboardOnActivation: model.composerClaimsKeyboardOnActivation,
          // The session's terminal, a second view of it, for a panel its agent opens (#219).
          liveTerminal: model.pane(for: id).map { pane in
            { focusRequest, onEscape, onScreen in
              AnyView(
                TerminalSurface(
                  pane: pane, session: pane.session, isActive: isActive,
                  focusRequest: focusRequest,
                  accessibilityTitle: terminalTitle(for: listed, pane: pane, in: model),
                  isMirror: true, onEscape: onEscape, onScreen: onScreen))
            }
          }
        )
        .conversationLinks(of: id, in: model)
        // The terminal's bar, and its button of the drawer, whichever form the session is
        // shown in.
        if let pane = model.pane(for: id) {
          Divider()
          TerminalStatusBar(
            pane: pane,
            accessory: model.terminals == nil
              ? nil : DrawerStatusButton(model: model, session: listed),
            restart: sessionRestart(for: id, in: model), canRestart: model.canRestart(listed),
            close: sessionClose(for: id, in: model))
        }
      }
      // Hidden, it keeps its width while the column changes for a moment, as a terminal does.
      // On screen too when the web view slides over it; not under a drag of the divider, where
      // it would leave a bare strip.
      .frame(width: widthHold.flatMap { !isActive || $0.isCovered ? $0.width : nil })
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .opacity(isActive ? 1 : 0)
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
      // A hidden composer must lose the keyboard: typed into, it would send to a session
      // nobody is looking at.
      .disabled(!isActive)
    }
  }
}

extension View {
  /// The question before archiving a session (#115). `presenting:` hands the session to the
  /// buttons, rather than having them read it back from the model: SwiftUI dismisses the dialog
  /// before running a button's action, and the dismissal clears the pending session — read there,
  /// Archive found nothing and did nothing.
  fileprivate func archiveConfirmation(
    model: AppModel, isOffered: Bool, suppressesConfirmation: Binding<Bool>,
    message: @escaping (WorkSession) -> String
  ) -> some View {
    confirmationDialog(
      model.pendingArchive.map {
        Text("Archive “\($0.name)”?", bundle: .module, comment: "A session's name.")
      } ?? Text("Archive this session?", bundle: .module),
      isPresented: Binding(
        get: { isOffered },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelArchive()
        }
      ),
      titleVisibility: .visible,
      presenting: model.pendingArchive
    ) { session in
      Button(LocalizedStringResource("Archive", bundle: .module)) {
        let askAgain = !suppressesConfirmation.wrappedValue
        Task { await model.archive(session.id, askAgain: askAgain) }
      }
      Button(LocalizedStringResource("Cancel", bundle: .module), role: .cancel) {
        model.cancelArchive()
      }
    } message: { session in
      Text(message(session))
    }
  }
}
