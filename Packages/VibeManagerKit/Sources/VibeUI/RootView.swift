import Foundation
import SwiftUI
import VibeApplication
import VibeDomain
import VibeTerminalUI

public struct RootView: View {
  private let model: AppModel
  /// The widths the columns open at, taken once the stored layout has been read and then left
  /// alone. Handing the measured width back as the column's ideal width would close the loop —
  /// measure, store, propose again, resize — and fight the drag the user is in the middle of.
  @State private var idealWidths: IdealColumnWidths?

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        ProgressView("Loading sessions…")
          .controlSize(.large)
      case .loaded:
        workspace
      case .failed(let message, let canRestoreBackup):
        ContentUnavailableView {
          Label("Sessions unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          if canRestoreBackup {
            Button("Restore Backup") {
              Task { await model.restoreBackup() }
            }
            .buttonStyle(.borderedProminent)
          }
          Button("Try Again") {
            Task { await model.reload() }
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
    .sheet(
      isPresented: Binding(
        get: { model.isPresentingNewSession },
        set: { isPresented in
          guard !isPresented else { return }
          model.cancelNewSession()
        }
      )
    ) {
      if let sheetModel = model.newSessionModel {
        NewSessionSheet(
          model: sheetModel,
          defaultWorkingDirectoryPath: model.newSessionDefaultWorkingDirectoryPath,
          created: { creation in Task { await model.complete(creation) } },
          cancelled: { model.cancelNewSession() }
        )
      }
    }
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
            dismiss: { model.dismissRefreshFailure() }
          )
          Divider()
        }
        if let warning = model.detachWarning {
          DetachWarningBanner(warning: warning) { model.dismissDetachWarning() }
          Divider()
        }
        detail
      }
      // No shortcut here: ⌘N belongs to the New Session menu command, which owns it for the
      // whole application. Repeating it bound the same key twice, under two conditions.
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            model.beginNewSession()
          } label: {
            Label("New Session", systemImage: "plus")
          }
          .disabled(!model.canCreateSession)
        }
        ToolbarItem(placement: .primaryAction) {
          // Never disabled: with the column open and the selection gone, a disabled button
          // would be the only way to close it. The column says so itself instead.
          Button {
            model.layout.toggleInspector()
          } label: {
            Label(
              model.layout.columns.isInspectorVisible ? "Hide Context" : "Show Context",
              systemImage: "sidebar.right"
            )
          }
          .accessibilityValue(model.layout.columns.isInspectorVisible ? "Shown" : "Hidden")
        }
      }
      .inspector(isPresented: inspectorPresented) {
        Group {
          if let session = model.selectedSession {
            SessionContextInspector(
              session: session,
              resolution: model.resolution(forID: session.id)
            )
          } else {
            // The inspector is only reachable with a selection, but a session can disappear
            // under it: the column stays rather than snapping shut mid-refresh.
            ContentUnavailableView(
              "No session selected",
              systemImage: "sidebar.right",
              description: Text("Select a session to see its repositories and notes.")
            )
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
    // Archiving is reversible, so the question is short and says what actually happens. Cancel
    // is the default button: the pointer slip that opened this must not also answer it.
    // `presenting:` hands the session to the buttons, rather than having them read it back from
    // the model. SwiftUI dismisses the dialog before running a button's action, and the dismissal
    // clears the pending session — read there, Archive found nothing and did nothing.
    .confirmationDialog(
      model.pendingArchive.map { "Archive “\($0.name)”?" } ?? "Archive this session?",
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
      Button("Archive") {
        Task { await model.archive(session.id) }
      }
      Button("Cancel", role: .cancel) {
        model.cancelArchive()
      }
    } message: { session in
      Text(archiveConfirmationMessage(for: session))
    }
  }

  private func archiveConfirmationMessage(for session: WorkSession) -> String {
    let isRunning = model.pane(for: session.id)?.status == .running
    let agent = isRunning ? "Its running agent will be stopped. " : ""
    return """
      \(agent)Nothing is deleted: notes, repositories and Git metadata are kept, and the session \
      stays readable under Archived.
      """
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
      ZStack {
        ForEach(model.sessions) { listed in
          if let pane = model.pane(for: listed.id) {
            let isActive = listed.id == session.id
            // Started by the launcher, so switching sessions never restarts an agent.
            TerminalPaneView(model: pane, autoStart: false, isActive: isActive)
              .id(listed.id)
              .opacity(isActive ? 1 : 0)
              .allowsHitTesting(isActive)
              .accessibilityHidden(!isActive)
          }
        }

        // An archived session has no pane by construction — archiving released it — so its own
        // card is what the column shows, rather than the "no terminal" message of a session
        // that simply has not been started.
        if session.status == .archived {
          ArchivedSessionDetail(session: session) {
            Task { await model.restore(session.id) }
          }
        } else if model.pane(for: session.id) == nil {
          ContentUnavailableView {
            Label(session.name, systemImage: session.appearance.symbolName)
          } description: {
            Text(
              model.launchFailure(for: session.id)?.message
                ?? "This session has no running terminal in this window."
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
    } else {
      ContentUnavailableView {
        Label("No session yet", systemImage: "square.stack.3d.up")
      } description: {
        Text("Create one to start a terminal and its coding agent.")
      } actions: {
        Button("New Session") {
          model.beginNewSession()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canCreateSession)
      }
    }
  }
}

/// A store failure shown over a workspace that keeps working.
private struct RefreshFailureBanner: View {
  let failure: AppModel.RefreshFailure
  let retry: () -> Void
  let restore: () -> Void
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
        Button("Restore Backup", action: restore)
          .controlSize(.small)
      }
      Button("Try Again", action: retry)
        .controlSize(.small)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
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
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.quaternary)
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
        Text("This session is archived. Nothing was deleted.")
          .font(.callout)
        Spacer(minLength: 8)
        Button("Unarchive", action: restore)
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
            dateRow("Created", session.createdAt)
            if let closedAt = session.closedAt {
              dateRow("Closed", closedAt)
            }
            if let archivedAt = session.archivedAt {
              dateRow("Archived", archivedAt)
            }
          }
          .font(.callout)

          Text(
            """
            Repositories, Git metadata, notes and the initial prompt are kept, and are listed in \
            the context column. Unarchiving brings the session back as closed; restarting its \
            agent stays a separate, deliberate step.
            """
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

  private func dateRow(_ label: String, _ date: Date) -> some View {
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

private struct SessionSidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      ScopePicker(model: model)
      Divider()
      list
      Divider()
      SidebarFooter(model: model)
    }
    .searchable(
      text: Binding(get: { model.filter.searchText }, set: { model.setSearchText($0) }),
      placement: .sidebar,
      prompt: "Search sessions"
    )
  }

  private var list: some View {
    List(selection: Binding(get: { model.selectedSessionID }, set: { model.select($0) })) {
      ForEach(Array(model.visibleSessions.enumerated()), id: \.element.id) { index, session in
        SessionRow(
          session: session,
          status: SessionStatusPresentation.make(
            session: session,
            paneStatus: model.pane(for: session.id)?.status,
            resolution: model.resolution(forID: session.id)
          ),
          // Only the rows a shortcut can reach claim one.
          shortcutPosition: index < AppModel.shortcutPositionLimit ? index + 1 : nil,
          commands: SessionCommands(model: model, session: session)
        )
        .tag(session.id)
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if model.visibleSessions.isEmpty {
        emptyState
      }
    }
  }

  /// Three different silences, told apart. "Nothing here" and "nothing matched what you typed"
  /// look identical on screen and mean opposite things, and only one of them has a way out.
  @ViewBuilder
  private var emptyState: some View {
    if model.filter.isNarrowing {
      ContentUnavailableView {
        Label("No matching session", systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text("No session in \(model.filter.scope.label.lowercased()) matches this filter.")
      } actions: {
        Button("Clear Filter") { model.clearNarrowing() }
      }
    } else if model.filter.scope == .archived {
      ContentUnavailableView(
        "No archived session",
        systemImage: "archivebox",
        description: Text("Archived sessions are kept here, and can be unarchived at any time.")
      )
    } else {
      ContentUnavailableView(
        "No sessions",
        systemImage: "square.stack.3d.up",
        description: Text("Press ⌘N to create one.")
      )
    }
  }
}

/// The archive is never a trapdoor: its tab carries how much is in it, so a session put away is
/// still something the user knows is there.
private struct ScopePicker: View {
  let model: AppModel

  var body: some View {
    Picker(
      "Scope",
      selection: Binding(get: { model.filter.scope }, set: { model.setScope($0) })
    ) {
      ForEach(SessionScope.allCases, id: \.self) { scope in
        Text(label(for: scope)).tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .accessibilityLabel("Sessions shown")
  }

  private func label(for scope: SessionScope) -> String {
    guard scope == .archived, model.archivedSessionCount > 0 else { return scope.label }
    return "\(scope.label) (\(model.archivedSessionCount))"
  }
}

/// Sort and facets live at the foot of the column rather than above the list: they are consulted
/// rarely, and the rows are what the column is for.
private struct SidebarFooter: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        Picker(
          "Sort By",
          selection: Binding(get: { model.filter.sort }, set: { model.setSort($0) })
        ) {
          ForEach(SessionSort.allCases, id: \.self) { sort in
            Text(sort.label).tag(sort)
          }
        }
        .pickerStyle(.inline)

        if !model.availableProviderIDs.isEmpty {
          Divider()
          Section("Agent") {
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
          Section("Folder") {
            Button("Any folder") { model.setRepositoryFacet(nil) }
            ForEach(model.availableRepositoryPaths, id: \.self) { path in
              Button(displayPath(path)) { model.setRepositoryFacet(path) }
            }
          }
        }

        if model.filter.isNarrowing {
          Divider()
          Button("Clear Filter") { model.clearNarrowing() }
        }
      } label: {
        Label(model.filter.sort.label, systemImage: "arrow.up.arrow.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Spacer(minLength: 0)

      if model.filter.isNarrowing {
        Button {
          model.clearNarrowing()
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Filtering is on. Click to clear it.")
        .accessibilityLabel("Clear filter")
      }
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
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

  func close() { Task { await model.close(session.id) } }
  func requestArchive() { model.requestArchive(session.id) }
  func restore() { Task { await model.restore(session.id) } }
}

private struct SessionCommandButtons: View {
  let commands: SessionCommands

  var body: some View {
    if commands.canClose {
      Button("Close Session") { commands.close() }
    }
    if commands.canArchive {
      Button("Archive…") { commands.requestArchive() }
    }
    if commands.canRestore {
      Button("Unarchive") { commands.restore() }
    }
  }
}

private struct SessionRow: View {
  let session: WorkSession
  let status: SessionStatusPresentation
  let shortcutPosition: Int?
  let commands: SessionCommands

  var body: some View {
    HStack(spacing: 10) {
      SessionBadge(appearance: session.appearance)
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
          .foregroundStyle(tint)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let shortcutPosition {
        Text("⌘\(shortcutPosition)")
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
    .accessibilityLabel(SessionStatusPresentation.accessibilityLabel(for: session, status: status))
    // The same three commands, reachable without a pointer and without the menu bar.
    .accessibilityAction(named: "Close Session") {
      guard commands.canClose else { return }
      commands.close()
    }
    .accessibilityAction(named: "Archive") {
      guard commands.canArchive else { return }
      commands.requestArchive()
    }
    .accessibilityAction(named: "Unarchive") {
      guard commands.canRestore else { return }
      commands.restore()
    }
  }

  private var tint: Color {
    switch status.severity {
    case .normal: return .secondary
    case .attention: return .orange
    case .error: return .red
    }
  }
}
