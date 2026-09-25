import SwiftUI
import VibeApplication

// Presentation of one terminal: the surface itself plus a readable lifecycle state. The view
// knows nothing of process identifiers or descriptors.
public struct TerminalPaneView: View {
  /// Held, not stored in `@State`: `@State` keeps the value it was first given for as long as
  /// the view keeps its identity, so showing another session's pane in the same place went on
  /// displaying the first one. The model is an observable reference owned elsewhere.
  private let model: TerminalPaneModel
  /// A pane whose process someone else owns must not be started again when the view appears:
  /// re-showing a finished session would silently launch a second agent.
  private let autoStart: Bool
  /// False for a pane that stays mounted behind the one being shown.
  private let isActive: Bool
  private let accessibilityTitle: String

  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String = "Terminal"
  ) {
    self.model = model
    self.autoStart = autoStart
    self.isActive = isActive
    self.accessibilityTitle = accessibilityTitle
  }

  public var body: some View {
    VStack(spacing: 0) {
      // The surface is mounted from the start: its measured size is what the process is
      // launched with, so it has to exist before there is a process to show.
      TerminalSurface(
        pane: model, session: model.session, isActive: isActive, focusRequest: model.focusRequest,
        accessibilityTitle: accessibilityTitle
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if let failure = model.failure {
          ContentUnavailableView {
            Label("Terminal unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(failure.message)
          } actions: {
            Button("Try Again") {
              Task { await model.start() }
            }
          }
          .background(.background)
        } else if model.session == nil {
          ProgressView("Starting terminal…")
        }
      }

      Divider()
      TerminalStatusBar(
        status: model.status,
        stop: { Task { await model.stop() } },
        restart: { Task { await model.start() } }
      )
    }
    .task {
      guard autoStart else { return }
      await model.start()
    }
  }
}

private struct TerminalStatusBar: View {
  let status: TerminalPaneModel.Status
  let stop: () -> Void
  let restart: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: status.symbolName)
        .foregroundStyle(status.tint)
      Text(status.label)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      if status.isRunning {
        Button("Stop", action: stop)
          .controlSize(.small)
      } else {
        Button("Restart", action: restart)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

extension TerminalPaneModel.Status {
  var label: String {
    switch self {
    case .starting:
      return "Starting…"
    case .running:
      return "Running"
    case .exited(let code):
      return code == 0 ? "Finished" : "Exited with code \(code)"
    case .terminated(let signal):
      return "Terminated by signal \(signal)"
    case .failed(let message):
      return message
    }
  }

  var symbolName: String {
    switch self {
    case .starting:
      return "hourglass"
    case .running:
      return "play.circle"
    case .exited(let code):
      return code == 0 ? "checkmark.circle" : "xmark.circle"
    case .terminated:
      return "bolt.circle"
    case .failed:
      return "exclamationmark.triangle"
    }
  }

  var tint: Color {
    switch self {
    case .starting:
      return .secondary
    case .running:
      return .accentColor
    case .exited(let code):
      return code == 0 ? .green : .orange
    case .terminated:
      return .orange
    case .failed:
      return .red
    }
  }

  var isRunning: Bool {
    switch self {
    case .starting, .running:
      return true
    case .exited, .terminated, .failed:
      return false
    }
  }
}
