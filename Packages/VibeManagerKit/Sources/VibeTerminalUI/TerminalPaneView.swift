import SwiftUI
import VibeApplication

// Presentation of one terminal: the surface itself plus a readable lifecycle state. The view
// knows nothing of process identifiers or descriptors.
public struct TerminalPaneView: View {
  @State private var model: TerminalPaneModel

  public init(model: TerminalPaneModel) {
    _model = State(initialValue: model)
  }

  public var body: some View {
    VStack(spacing: 0) {
      Group {
        if let session = model.session {
          TerminalSurface(session: session)
        } else if let failure = model.failure {
          ContentUnavailableView {
            Label("Terminal unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(failure.message)
          } actions: {
            Button("Try Again") {
              Task { await model.start() }
            }
          }
        } else {
          ProgressView("Starting terminal…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      TerminalStatusBar(status: model.status) {
        Task { await model.stop() }
      }
    }
    .task {
      await model.start()
    }
  }
}

private struct TerminalStatusBar: View {
  let status: TerminalPaneModel.Status
  let stop: () -> Void

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
