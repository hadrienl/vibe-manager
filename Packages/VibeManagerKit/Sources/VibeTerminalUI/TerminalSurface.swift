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

  public init(pane: TerminalPaneModel, session: (any TerminalSession)?) {
    self.pane = pane
    self.session = session
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
    guard let session else { return }
    context.coordinator.attachIfNeeded(to: session)
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
  private let pane: TerminalPaneModel
  private weak var view: TerminalView?
  private var eventTask: Task<Void, Never>?
  private var attachedSessionID: SessionID?
  private let commands: AsyncStream<TerminalCommand>.Continuation
  private let commandTask: Task<Void, Never>

  init(pane: TerminalPaneModel) {
    self.pane = pane

    var continuation: AsyncStream<TerminalCommand>.Continuation?
    let stream = AsyncStream<TerminalCommand> { continuation = $0 }
    guard let continuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    commands = continuation
    // One consumer, one order: keystrokes and resizes reach the process in the order the user
    // made them, and a size measured before the process exists is remembered rather than lost.
    commandTask = Task { @MainActor [pane] in
      for await command in stream {
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
    commandTask.cancel()
  }

  func bind(to view: TerminalView) {
    self.view = view
  }

  func attachIfNeeded(to session: any TerminalSession) {
    guard attachedSessionID != session.id else { return }
    attachedSessionID = session.id
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
    attachedSessionID = nil
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
