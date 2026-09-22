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
          Button {
            model.layout.toggleInspector()
          } label: {
            Label("Context", systemImage: "sidebar.right")
          }
          .disabled(model.selectedSession == nil)
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

        if model.pane(for: session.id) == nil {
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
    List(selection: Binding(get: { model.selectedSessionID }, set: { model.select($0) })) {
      ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
        SessionRow(
          session: session,
          status: SessionStatusPresentation.make(
            session: session,
            paneStatus: model.pane(for: session.id)?.status,
            resolution: model.resolution(forID: session.id)
          ),
          // Only the first nine rows can be reached by a shortcut, so only they claim one.
          shortcutPosition: index < 9 ? index + 1 : nil
        )
        .tag(session.id)
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if model.sessions.isEmpty {
        ContentUnavailableView(
          "No sessions",
          systemImage: "square.stack.3d.up",
          description: Text("Press ⌘N to create one.")
        )
      }
    }
  }
}

private struct SessionRow: View {
  let session: WorkSession
  let status: SessionStatusPresentation
  let shortcutPosition: Int?

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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(SessionStatusPresentation.accessibilityLabel(for: session, status: status))
  }

  private var tint: Color {
    switch status.severity {
    case .normal: return .secondary
    case .attention: return .orange
    case .error: return .red
    }
  }
}
