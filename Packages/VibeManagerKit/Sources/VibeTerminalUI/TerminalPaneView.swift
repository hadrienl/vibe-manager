import SwiftUI
import VibeApplication
import VibeConversationUI

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
  /// See `TerminalStatusBar.close`. Left out, the pane has no status bar.
  private let close: (() -> Void)?
  @Environment(\.paneWidthHold) private var widthHold

  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String? = nil, showsStatusBar: Bool = true,
    statusAccessory: Accessory?, claimsKeyboardOnActivation: Bool = true,
    restart: (() -> Void)? = nil, canRestart: Bool = true, close: (() -> Void)? = nil
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
    self.close = close
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
      // From left to right in every language, Arabic included (#215).
      .environment(\.layoutDirection, .leftToRight)
      // A terminal keeps its size while its column changes for a moment, and takes the last one
      // in a single reflow: what it leaves bare meanwhile is the colour of its own background.
      .frame(width: widthHold?.width, alignment: .leading)
      .frame(
        minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .leading
      )
      .background(Color(nsColor: .textBackgroundColor))
      .clipped()
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
          // The whole pane: the surface behind, mounted with its cursor, read as a terminal that
          // runs beside the card (#382).
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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

      // Only a session's terminal has one: its Close is the one way its agent is stopped from here.
      if showsStatusBar, let close {
        Divider()
        TerminalStatusBar(
          pane: model, accessory: statusAccessory, restart: restart, canRestart: canRestart,
          close: close)
      }
    }
    .task {
      guard autoStart else { return }
      await model.start()
    }
  }
}

/// The foot of a session's terminal: its process's state, Close Session or Restart, and what the
/// app puts beside them. Also under the conversation view, which shows the same session in
/// another form.
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
  /// What ends the process of a session's terminal: the session's own Close, which asks first
  /// when an agent is at work (#238), never the pane's process stopped behind the user's back.
  private let close: () -> Void
  @State private var density = StatusBarDensity.full

  public init(
    pane: TerminalPaneModel, accessory: Accessory?, restart: (() -> Void)? = nil,
    canRestart: Bool = true, close: @escaping () -> Void
  ) {
    self.pane = pane
    self.accessory = accessory
    self.restartAction = restart
    self.canRestart = canRestart
    self.close = close
  }

  private var status: TerminalPaneModel.Status { pane.status }

  func stop() { close() }

  private func restart() {
    if let restartAction {
      restartAction()
    } else {
      Task { await pane.start() }
    }
  }

  public var body: some View {
    HStack(spacing: 8) {
      // Nothing while the agent runs: the bar is the agent's buttons. Any other state is an icon,
      // its words in its tooltip (#575).
      if !status.isRunningProcess {
        Image(systemName: status.symbolName)
          .foregroundStyle(status.tint)
          .instantTooltip(Text(status.label))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(status.label))
          .accessibilityAddTraits(.isStaticText)
          .statusBarItem("state")
      }
      Spacer(minLength: 0)
      if let accessory {
        accessory
      }
      if status.isRunning {
        iconButton(
          "power",
          Text(
            "Close Session…", bundle: .module,
            comment: "Stops a session's agent, asking first when it is at work."),
          action: stop
        )
        .statusBarItem("close")
      } else {
        iconButton(
          "arrow.clockwise",
          Text("Restart", bundle: .module, comment: "Starts the terminal's process again."),
          action: restart
        )
        .disabled(!canRestart)
        .statusBarItem("restart")
      }
    }
    .environment(\.statusBarDensity, density)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .coordinateSpace(.named(statusBarSpace))
    // The step is chosen from the bar's own width, once for all its buttons.
    .onGeometryChange(for: StatusBarDensity.self) {
      StatusBarDensity.fitting($0.size.width)
    } action: {
      density = $0
    }
  }

  /// A button drawn as its icon, its name in its tooltip and for VoiceOver.
  private func iconButton(_ symbol: String, _ name: Text, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .controlSize(.small)
    // Outside the button, so that a greyed-out Restart says what it is too.
    .instantTooltip(name)
    .accessibilityLabel(name)
  }
}

extension TerminalPaneView where Accessory == EmptyView {
  /// A pane with nothing beside its status bar's button: a side terminal of the drawer.
  public init(
    model: TerminalPaneModel, autoStart: Bool = true, isActive: Bool = true,
    accessibilityTitle: String? = nil, showsStatusBar: Bool = true,
    claimsKeyboardOnActivation: Bool = true, restart: (() -> Void)? = nil, canRestart: Bool = true,
    close: (() -> Void)? = nil
  ) {
    self.init(
      model: model, autoStart: autoStart, isActive: isActive,
      accessibilityTitle: accessibilityTitle, showsStatusBar: showsStatusBar,
      statusAccessory: nil, claimsKeyboardOnActivation: claimsKeyboardOnActivation,
      restart: restart, canRestart: canRestart, close: close)
  }
}

extension TerminalStatusBar where Accessory == EmptyView {
  public init(
    pane: TerminalPaneModel, restart: (() -> Void)? = nil, canRestart: Bool = true,
    close: @escaping () -> Void
  ) {
    self.init(pane: pane, accessory: nil, restart: restart, canRestart: canRestart, close: close)
  }
}

extension TerminalPaneModel.Status {
  public var label: String {
    switch self {
    case .starting:
      return String(localized: "Starting…", bundle: .module, comment: "A terminal's state.")
    case .running:
      return String(localized: "Running", bundle: .module, comment: "A terminal's state.")
    case .exited(let code):
      return code == 0
        ? String(localized: "Finished", bundle: .module, comment: "A terminal's state.")
        : String(
          localized: "Process failed (code \(String(code)))", bundle: .module,
          comment: "A terminal's state: its process ended with this exit status, other than 0.")
    case .terminated(let signal):
      return String(
        localized: "Process interrupted (signal \(String(signal)))", bundle: .module,
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

  /// Whether the process runs, its start over: the one state the bar shows nothing for.
  var isRunningProcess: Bool {
    if case .running = self { return true }
    return false
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
