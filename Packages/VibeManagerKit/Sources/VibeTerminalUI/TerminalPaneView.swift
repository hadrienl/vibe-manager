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
  private let accessibilityTitle: String?

  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String? = nil
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
            Label {
              Text("Terminal unavailable", bundle: .module)
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
          } description: {
            Text(failure.message)
          } actions: {
            Button {
              Task { await model.start() }
            } label: {
              Text("Try Again", bundle: .module)
            }
          }
          .background(.background)
        } else if model.session == nil {
          ProgressView {
            Text("Starting terminal…", bundle: .module)
          }
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
        Button(action: stop) {
          Text("Stop", bundle: .module, comment: "Stops the terminal's process.")
        }
        .controlSize(.small)
      } else {
        Button(action: restart) {
          Text("Restart", bundle: .module, comment: "Starts the terminal's process again.")
        }
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
      return String(localized: "Starting…", bundle: .module, comment: "A terminal's state.")
    case .running:
      return String(localized: "Running", bundle: .module, comment: "A terminal's state.")
    case .exited(let code):
      return code == 0
        ? String(localized: "Finished", bundle: .module, comment: "A terminal's state.")
        : String(
          localized: "Exited with code \(String(code))", bundle: .module,
          comment: "A terminal's state: its process ended with this exit status.")
    case .terminated(let signal):
      return String(
        localized: "Terminated by signal \(String(signal))", bundle: .module,
        comment: "A terminal's state: its process was killed by this signal number.")
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
