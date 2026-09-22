import Foundation
import SwiftUI
import VibeApplication
import VibeDomain
import VibeTerminalUI

public struct RootView: View {
  private let model: AppModel

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
    .frame(minWidth: 760, minHeight: 480)
    .task {
      await model.load()
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
    NavigationSplitView {
      SessionSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
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
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            model.beginNewSession()
          } label: {
            Label("New Session", systemImage: "plus")
          }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(!model.canCreateSession)
        }
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let session = model.selectedSession {
      if model.pane(for: session.id) != nil {
        // Every terminal stays mounted, and changing session only changes which one is shown.
        // Rebuilding the selected one instead meant a fresh, empty terminal for the frame it
        // took to replay the history — and it threw away the scroll position with it.
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
        }
      } else {
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

private struct SessionSidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    List(selection: Binding(get: { model.selectedSessionID }, set: { model.select($0) })) {
      ForEach(model.sessions) { session in
        SessionRow(session: session, isRunning: model.pane(for: session.id)?.status == .running)
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
  let isRunning: Bool

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
        // Status is written out, never carried by colour alone.
        Label(isRunning ? "Running" : session.status.rawValue.capitalized, systemImage: symbolName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private var symbolName: String {
    if isRunning { return "play.circle" }
    switch session.status {
    case .active: return "play.circle"
    case .closed: return "pause.circle"
    case .archived: return "archivebox"
    }
  }
}
