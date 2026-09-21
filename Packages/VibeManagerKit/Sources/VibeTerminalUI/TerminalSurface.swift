import SwiftTerm
import SwiftUI
import VibeApplication

// The only place that knows about the emulator. Views above it see a session and a state, never
// a descriptor, a process identifier or a SwiftTerm type.
public struct TerminalSurface: NSViewRepresentable {
  private let session: any TerminalSession

  public init(session: any TerminalSession) {
    self.session = session
  }

  public func makeCoordinator() -> TerminalSurfaceCoordinator {
    TerminalSurfaceCoordinator(session: session)
  }

  public func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView()
    view.terminalDelegate = context.coordinator
    view.configureNativeColors()
    context.coordinator.bind(to: view)
    return view
  }

  public func updateNSView(_ nsView: TerminalView, context: Context) {}

  public static func dismantleNSView(
    _ nsView: TerminalView,
    coordinator: TerminalSurfaceCoordinator
  ) {
    coordinator.unbind()
  }
}

// Input and resizes reach the session through one serial channel. Unstructured tasks have no
// ordering guarantee between them, so a task per delegate callback would let fast typing, a pasted
// chunk split across several callbacks, or two resizes during a window drag arrive out of order.
private enum TerminalCommand: Sendable {
  case write([UInt8])
  case resize(TerminalSize)
}

@MainActor
public final class TerminalSurfaceCoordinator: NSObject, TerminalViewDelegate {
  private let session: any TerminalSession
  private weak var view: TerminalView?
  private var eventTask: Task<Void, Never>?
  private let commands: AsyncStream<TerminalCommand>.Continuation
  private let commandTask: Task<Void, Never>

  init(session: any TerminalSession) {
    self.session = session

    var continuation: AsyncStream<TerminalCommand>.Continuation?
    let stream = AsyncStream<TerminalCommand> { continuation = $0 }
    guard let continuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    commands = continuation
    commandTask = Task { [session] in
      for await command in stream {
        switch command {
        case .write(let bytes):
          await session.write(bytes)
        case .resize(let size):
          await session.resize(to: size)
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
    eventTask?.cancel()
    eventTask = Task { [session] in
      let attachment = await session.attach()
      // The backlog is replayed first so that a view created after the process started shows
      // what has already been printed.
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
