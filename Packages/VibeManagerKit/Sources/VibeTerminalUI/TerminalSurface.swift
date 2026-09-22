import SwiftTerm
import SwiftUI
import VibeApplication
import VibeDomain

/// The terminal view, mounted before the process exists.
///
/// It has to be: its own layout is what tells the pane how many columns and rows the agent will
/// be started with. Until a session appears it simply has nothing to display.
public struct TerminalSurface: NSViewRepresentable {
  private let pane: TerminalPaneModel
  private let session: (any TerminalSession)?
  /// Panes that are not on screen stay mounted, so they must not keep the keyboard.
  private let isActive: Bool

  public init(pane: TerminalPaneModel, session: (any TerminalSession)?, isActive: Bool = true) {
    self.pane = pane
    self.session = session
    self.isActive = isActive
  }

  public func makeCoordinator() -> TerminalSurfaceCoordinator {
    TerminalSurfaceCoordinator(pane: pane)
  }

  public func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView()
    view.terminalDelegate = context.coordinator
    view.configureNativeColors()
    context.coordinator.bind(to: view)
    return view
  }

  public func updateNSView(_ nsView: TerminalView, context: Context) {
    // The pane can be replaced under a view SwiftUI keeps identical — a relaunch of the same
    // session builds a new one — so the coordinator is told which pane is the live one.
    context.coordinator.adopt(pane: pane)
    if let session {
      context.coordinator.attachIfNeeded(to: session)
    }
    context.coordinator.followActivation(isActive, in: nsView)
  }

  public static func dismantleNSView(
    _ nsView: TerminalView,
    coordinator: TerminalSurfaceCoordinator
  ) {
    coordinator.unbind()
  }
}

private enum TerminalCommand: Sendable {
  case write([UInt8])
  case resize(TerminalSize)
}

@MainActor
public final class TerminalSurfaceCoordinator: NSObject, TerminalViewDelegate {
  private var pane: TerminalPaneModel
  private weak var view: TerminalView?
  private var eventTask: Task<Void, Never>?
  // Object identity, not `session.id`: the id belongs to the work session and is reused by every
  // process started for it, so it cannot tell a restarted session from the one already attached.
  private var attachedSession: ObjectIdentifier?
  private var wasActive: Bool?
  private let commands: AsyncStream<TerminalCommand>.Continuation
  private var commandTask: Task<Void, Never>?

  init(pane: TerminalPaneModel) {
    self.pane = pane

    var continuation: AsyncStream<TerminalCommand>.Continuation?
    let stream = AsyncStream<TerminalCommand> { continuation = $0 }
    guard let continuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    commands = continuation
    super.init()
    // One consumer, one order: keystrokes and resizes reach the process in the order the user
    // made them, and a size measured before the process exists is remembered rather than lost.
    commandTask = Task { @MainActor [weak self] in
      for await command in stream {
        // Read the pane on each command rather than capturing it: `adopt` can have replaced it.
        guard let pane = self?.pane else { continue }
        switch command {
        case .write(let bytes):
          await pane.write(bytes)
        case .resize(let size):
          await pane.reportViewportSize(size)
        }
      }
    }
  }

  deinit {
    commands.finish()
    commandTask?.cancel()
  }

  func bind(to view: TerminalView) {
    self.view = view
  }

  /// Points the coordinator at the pane the view now renders.
  ///
  /// A relaunch replaces the pane while SwiftUI keeps the same view identity, so without this the
  /// coordinator would keep writing keystrokes and viewport sizes into a discarded model.
  func adopt(pane: TerminalPaneModel) {
    guard self.pane !== pane else { return }
    self.pane = pane
    eventTask?.cancel()
    eventTask = nil
    attachedSession = nil
  }

  /// Keystrokes must reach the terminal the user is looking at, and only that one: a hidden pane
  /// that kept the first responder would quietly receive what was typed for its neighbour.
  ///
  /// Only a *change* of activation moves the keyboard. Claiming it on every update would fight
  /// the user for it: the surrounding view redraws whenever a pane's status changes, and the
  /// active terminal would steal the focus back from the sidebar mid-keystroke.
  func followActivation(_ isActive: Bool, in view: TerminalView) {
    // No window yet: nothing can hold the keyboard, and this is not the change we are waiting
    // for — leave the state untouched so the next update still acts on it.
    guard let window = view.window else { return }
    guard wasActive != isActive else { return }
    wasActive = isActive

    if isActive {
      window.makeFirstResponder(view)
    } else if window.firstResponder === view {
      window.makeFirstResponder(nil)
    }
  }

  func attachIfNeeded(to session: any TerminalSession) {
    let identity = ObjectIdentifier(session)
    guard attachedSession != identity else { return }
    attachedSession = identity
    eventTask?.cancel()
    eventTask = Task { [session] in
      let attachment = await session.attach()
      feed(attachment.history.bytes)
      for await event in attachment.events {
        guard !Task.isCancelled else { return }
        if case .output(let bytes) = event {
          feed(bytes)
        }
      }
    }
  }

  func unbind() {
    eventTask?.cancel()
    eventTask = nil
    attachedSession = nil
    view = nil
  }

  private func feed(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    view?.feed(byteArray: bytes[...])
  }

  nonisolated public func send(source: TerminalView, data: ArraySlice<UInt8>) {
    commands.yield(.write([UInt8](data)))
  }

  nonisolated public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    commands.yield(.resize(TerminalSize(columns: newCols, rows: newRows)))
  }

  nonisolated public func scrolled(source: TerminalView, position: Double) {}

  nonisolated public func setTerminalTitle(source: TerminalView, title: String) {}

  nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  nonisolated public func clipboardCopy(source: TerminalView, content: Data) {}

  nonisolated public func requestOpenLink(
    source: TerminalView,
    link: String,
    params: [String: String]
  ) {}

  nonisolated public func bell(source: TerminalView) {}

  nonisolated public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

  nonisolated public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
