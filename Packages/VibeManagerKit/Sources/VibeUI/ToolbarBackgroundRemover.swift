import AppKit
import SwiftUI
import VibeApplication

/// Keeps the toolbar see-through over every column, in a window and in full screen (#317).
///
/// Each column of the split view has a background under the toolbar. macOS 26 draws it, whole or
/// in part, wherever no scroll edge effect lies beneath: opaque above the web view, above the whole
/// detail once the inspector is open, and, in full screen, as a 91 pt veil left in the split view
/// after the inspector folds. What scrolls under the toolbar — the conversation — blurs itself
/// with its own edge effect, which this leaves alone (`toolbarBackgroundVisibility(.hidden)` would
/// take it away too).
///
/// Nothing here moves or resizes AppKit's views: the backgrounds of the window, and of the window
/// that holds the toolbar in full screen, are hidden, and hidden again as soon as AppKit shows one,
/// before it is drawn. Stopped, it shows them again.
@MainActor
final class ToolbarBackgroundRemover {
  /// AppKit's private classes: matched by name, nothing is found if they are renamed.
  static let backgroundClassName = "NSTitlebarBackgroundView"
  static let fullScreenToolbarWindowClassName = "NSToolbarFullScreenWindow"

  private weak var window: NSWindow?
  private var columns: WorkspaceColumns?
  private var hidden: [Hidden] = []
  private var observers: [NSObjectProtocol] = []
  private var pendingCheck: Task<Void, Never>?

  private struct Hidden {
    weak var view: NSView?
    /// AppKit showing it again — each time the inspector opens, or the window enters full
    /// screen — hidden at once: shown even for a moment, it flickers over the column.
    let shown: NSKeyValueObservation
  }

  /// Watches `window` from now on; another window replaces the one watched.
  func watch(_ window: NSWindow) {
    guard window !== self.window else { return }
    stop()
    self.window = window
    let center = NotificationCenter.default
    // Where AppKit makes new backgrounds or moves them to another window.
    let checks: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
      NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
    ]
    for name in checks {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.check() }
        })
    }
    check()
  }

  /// Looks again as a column folds or unfolds, and once it has finished.
  func columnsChanged(to columns: WorkspaceColumns) {
    guard columns != self.columns else { return }
    self.columns = columns
    pendingCheck?.cancel()
    pendingCheck = Task { [weak self] in
      for delay in [Duration.zero, .milliseconds(500), .milliseconds(1500)] {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        self?.check()
      }
    }
  }

  func check() {
    guard let window, let root = window.contentView?.superview ?? window.contentView else {
      return
    }
    // In full screen, the toolbar and the backgrounds of its columns are in a window of their own.
    let toolbarRoots = NSApp.windows
      .filter {
        $0.isVisible && NSStringFromClass(type(of: $0)) == Self.fullScreenToolbarWindowClassName
      }
      .compactMap { $0.contentView?.superview ?? $0.contentView }
    update(roots: [root] + toolbarRoots)
  }

  /// What `check` does, for the hierarchies under `roots`.
  func update(roots: [NSView]) {
    hidden.removeAll { $0.view == nil }
    for view in roots.flatMap(Self.backgrounds(in:)) {
      if hidden.contains(where: { $0.view === view }) {
        view.isHidden = true
      } else if !view.isHidden {
        hide(view)
      }
    }
  }

  private func hide(_ view: NSView) {
    view.isHidden = true
    let shown = view.observe(\.isHidden) { view, _ in
      MainActor.assumeIsolated {
        if !view.isHidden { view.isHidden = true }
      }
    }
    hidden.append(Hidden(view: view, shown: shown))
  }

  /// The toolbar backgrounds under `root`, in the split views and the title bar alike.
  static func backgrounds(in root: NSView) -> [NSView] {
    var found: [NSView] = []
    var queue = [root]
    while !queue.isEmpty {
      let view = queue.removeFirst()
      if NSStringFromClass(type(of: view)) == backgroundClassName {
        found.append(view)
        continue
      }
      // What scrolls — a conversation, a list — holds no toolbar background: not walked.
      guard !(view is NSScrollView) else { continue }
      queue += view.subviews
    }
    return found
  }

  /// Shows what it hid and watches nothing more.
  func stop() {
    for entry in hidden {
      entry.shown.invalidate()
      entry.view?.isHidden = false
    }
    hidden = []
    pendingCheck?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    window = nil
  }
}

/// Puts `ToolbarBackgroundRemover` on the window it is drawn in, and has it look again whenever
/// the columns change.
struct ToolbarBackgroundRemoverReader: NSViewRepresentable {
  let columns: WorkspaceColumns

  func makeCoordinator() -> ToolbarBackgroundRemover { ToolbarBackgroundRemover() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let remover = context.coordinator
    DispatchQueue.main.async { [weak view] in
      if let window = view?.window { remover.watch(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Out of its window for a moment, it keeps watching the one it had.
    if let window = nsView.window { context.coordinator.watch(window) }
    context.coordinator.columnsChanged(to: columns)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: ToolbarBackgroundRemover) {
    coordinator.stop()
  }
}
