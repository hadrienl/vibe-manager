import AppKit

/// When a click on a link in a terminal opens it (#186).
///
/// SwiftTerm asks to open a link on every release without a drag over it — the second release of
/// a double click too, after that click has selected the word. A double click must select, not
/// open: a plain click therefore waits for the double-click interval, and the next press cancels
/// it. ⌘-click, which cannot be the start of a double click that selects, opens at once.
@MainActor
final class TerminalLinkClicks {
  enum Decision: Equatable {
    case open
    case wait
    case ignore
  }

  static func decide(clickCount: Int, command: Bool) -> Decision {
    if clickCount > 1 { return .ignore }
    return command ? .open : .wait
  }

  /// Read at each click: the user can change it in System Settings while the app runs.
  var interval: () -> Duration = { .seconds(NSEvent.doubleClickInterval) }
  private let sleep: @Sendable (Duration) async throws -> Void
  private var pending: Task<Void, Never>?

  init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
  {
    self.sleep = sleep
  }

  var isWaiting: Bool { pending != nil }

  func linkClicked(clickCount: Int, command: Bool, open: @escaping @MainActor @Sendable () -> Void) {
    cancel()
    switch Self.decide(clickCount: clickCount, command: command) {
    case .open:
      open()
    case .ignore:
      break
    case .wait:
      let delay = interval()
      pending = Task { [weak self, sleep] in
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled else { return }
        self?.pending = nil
        open()
      }
    }
  }

  /// A press: the start of a double click, or of anything else, and not the click that waited.
  func pointerDown() {
    cancel()
  }

  private func cancel() {
    pending?.cancel()
    pending = nil
  }
}
