import Foundation
import SwiftUI
import VibeApplication
import VibeTerminalUI

public struct RootView: View {
  @State private var model: AppModel
  private let terminal: TerminalPaneModel

  public init(model: AppModel, terminal: TerminalPaneModel) {
    _model = State(initialValue: model)
    self.terminal = terminal
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        ProgressView("Loading sessions…")
          .controlSize(.large)
      case .loaded:
        // Session creation arrives with #7; until then the pane runs a login shell so the
        // terminal can be exercised end to end.
        TerminalPaneView(model: terminal)
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
    .overlay(alignment: .bottomLeading) {
      AgentDiagnosticsSummary(
        diagnostics: model.agentDiagnostics,
        isRefreshing: model.isRefreshingAgents,
        refresh: { Task { await model.refreshAgents(forceRefresh: true) } }
      )
      .padding()
    }
    .overlay(alignment: .bottomTrailing) {
      Text(buildVersion)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding()
        .accessibilityLabel("Vibe Manager \(buildVersion)")
    }
    .task {
      await model.load()
    }
  }

  private var buildVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    switch (version, build) {
    case (.some(let version), .some(let build)):
      return "Version \(version) (\(build))"
    case (.some(let version), .none):
      return "Version \(version)"
    default:
      return "Development build"
    }
  }
}
