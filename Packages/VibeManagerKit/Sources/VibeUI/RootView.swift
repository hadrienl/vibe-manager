import Foundation
import SwiftUI

public struct RootView: View {
  @State private var model: AppModel

  public init(model: AppModel) {
    _model = State(initialValue: model)
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        ProgressView("Loading sessions…")
          .controlSize(.large)
      case .loaded(let sessions) where sessions.isEmpty:
        ContentUnavailableView {
          Label("No work sessions", systemImage: "terminal")
        } description: {
          Text("Create a session to start working with your coding agent.")
        }
      case .loaded(let sessions):
        ContentUnavailableView(
          "Foundation ready",
          systemImage: "hammer",
          description: Text("Loaded \(sessions.count) work sessions.")
        )
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
