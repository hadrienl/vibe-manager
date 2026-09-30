import SwiftUI
import VibeApplication

// Presentation of one terminal: the surface itself plus a readable lifecycle state. The view
// knows nothing of process identifiers or descriptors.
public struct TerminalPaneView<Accessory: View>: View {
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
  /// False for a side terminal of the drawer (#43): its tab carries its state.
  private let showsStatusBar: Bool
  /// Shown in the status bar before its own button: the drawer's button, for the agent's terminal.
  /// A type of its own rather than an `AnyView`, which never compares equal to the last one: the
  /// pane would be evaluated again each time the window is (#254).
  private let statusAccessory: Accessory?
  /// See `TerminalSurface.claimsKeyboardOnActivation`.
  private let claimsKeyboardOnActivation: Bool
  /// See `TerminalStatusBar.restart`.
  private let restart: (() -> Void)?
  /// See `TerminalStatusBar.canRestart`.
  private let canRestart: Bool

  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String? = nil, showsStatusBar: Bool = true,
    statusAccessory: Accessory?, claimsKeyboardOnActivation: Bool = true,
    restart: (() -> Void)? = nil, canRestart: Bool = true
  ) {
    self.model = model
    self.autoStart = autoStart
    self.isActive = isActive
    self.accessibilityTitle = accessibilityTitle
    self.showsStatusBar = showsStatusBar
    self.statusAccessory = statusAccessory
    self.claimsKeyboardOnActivation = claimsKeyboardOnActivation
    self.restart = restart
    self.canRestart = canRestart
  }

  public var body: some View {
    VStack(spacing: 0) {
      // The surface is mounted from the start: its measured size is what the process is
      // launched with, so it has to exist before there is a process to show.
      TerminalSurface(
        pane: model, session: model.session, isActive: isActive, focusRequest: model.focusRequest,
        accessibilityTitle: accessibilityTitle,
        claimsKeyboardOnActivation: claimsKeyboardOnActivation
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
        } else if model.isCatchingUp {
          ProgressView {
            Text("Updating the terminal…", bundle: .module)
          }
        }
      }

      if showsStatusBar {
        Divider()
        TerminalStatusBar(
          pane: model, accessory: statusAccessory, restart: restart, canRestart: canRestart)
      }
    }
    .task {
      guard autoStart else { return }
      await model.start()
    }
  }
}

/// The foot of a session's terminal: its process's state, Stop or Restart, and what the app puts
/// beside them. Also under the conversation view, which shows the same session in another form.
public struct TerminalStatusBar<Accessory: View>: View {
  private let pane: TerminalPaneModel
  private let accessory: Accessory?
  /// What Restart does. Left out, the pane starts its process again exactly as it was launched.
  /// An agent's terminal must not (#138): its command line names a conversation that exists by
  /// now — `claude --session-id` then refuses it as already in use — and nothing the app watches
  /// a launch with would be armed. It is given the session's own restart instead.
  private let restartAction: (() -> Void)?
  /// False while Restart would be refused — the session's agent unavailable, a restart or a
  /// switch of agent under way: the button is shown disabled, as the menu's command is.
  private let canRestart: Bool

  public init(
    pane: TerminalPaneModel, accessory: Accessory?, restart: (() -> Void)? = nil,
    canRestart: Bool = true
  ) {
    self.pane = pane
    self.accessory = accessory
    self.restartAction = restart
    self.canRestart = canRestart
  }

  private var status: TerminalPaneModel.Status { pane.status }

  private func stop() { Task { await pane.stop() } }

  private func restart() {
    if let restartAction {
      restartAction()
    } else {
      Task { await pane.start() }
    }
  }

  public var body: some View {
    HStack(spacing: 8) {
      Image(systemName: status.symbolName)
        .foregroundStyle(status.tint)
      Text(status.label)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      if let accessory {
        accessory
      }
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
        .disabled(!canRestart)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

extension TerminalPaneView where Accessory == EmptyView {
  /// A pane with nothing beside its status bar's button: a side terminal of the drawer.
  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String? = nil, showsStatusBar: Bool = true,
    claimsKeyboardOnActivation: Bool = true, restart: (() -> Void)? = nil, canRestart: Bool = true
  ) {
    self.init(
      model: model, autoStart: autoStart, isActive: isActive,
      accessibilityTitle: accessibilityTitle, showsStatusBar: showsStatusBar,
      statusAccessory: nil, claimsKeyboardOnActivation: claimsKeyboardOnActivation,
      restart: restart, canRestart: canRestart)
  }
}

extension TerminalStatusBar where Accessory == EmptyView {
  public init(
    pane: TerminalPaneModel, restart: (() -> Void)? = nil, canRestart: Bool = true
  ) {
    self.init(pane: pane, accessory: nil, restart: restart, canRestart: canRestart)
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
