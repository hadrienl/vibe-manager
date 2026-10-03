import AppKit
import SwiftUI
import VibeApplication

/// Hides the toolbar background AppKit leaves behind in a full-screen window (#317).
///
/// Each column of the split view has a background under the toolbar, with the toolbar's edge
/// effect. In a window, they sit in the split view; in full screen, AppKit moves them into the
/// window that holds the toolbar. Now and then — after the inspector folds, it seems — the main
/// column's stays in the split view, stretched to the height the title bar has during the change
/// of mode (91 pt beside the notch), and veils the top of whatever the column shows until the
/// window leaves full screen. Hidden, the column looks as it should.
///
/// Nothing here moves or resizes AppKit's views: a background found in the split view of a
/// full-screen window is hidden, and shown again as soon as the window leaves full screen, where
/// that place is its own again.
@MainActor
final class FullScreenTitlebarRepair {
  /// AppKit's private class: matched by name, nothing is found if it is renamed.
  static let backgroundClassName = "NSTitlebarBackgroundView"

  private weak var window: NSWindow?
  private var columns: WorkspaceColumns?
  private var hidden: [Hidden] = []
  private var observers: [NSObjectProtocol] = []
  private var pendingCheck: Task<Void, Never>?

  private struct Hidden {
    weak var view: NSView?
    /// Its moves: AppKit taking it back to the toolbar's window says so in no other way.
    let observer: NSObjectProtocol
  }

  /// Watches `window` from now on; another window replaces the one watched.
  func watch(_ window: NSWindow) {
    guard window !== self.window else { return }
    stop()
    self.window = window
    let center = NotificationCenter.default
    // Not at each resize: entering full screen, AppKit takes the backgrounds through the split
    // view on their way to the toolbar's window, and they must not be hidden there.
    let checks: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification, NSWindow.didChangeScreenNotification,
      NSWindow.didBecomeKeyNotification,
    ]
    for name in checks {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.check() }
        })
    }
    // Shown again once out of full screen, where the split view is its place: not before, since
    // a window that fails to leave full screen would get the veil back.
    observers.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.showHidden() }
      })
    check()
  }

  /// Looks again once a column has finished folding or unfolding.
  func columnsChanged(to columns: WorkspaceColumns) {
    guard columns != self.columns else { return }
    self.columns = columns
    pendingCheck?.cancel()
    pendingCheck = Task { [weak self] in
      for delay in [Duration.milliseconds(500), .milliseconds(1500)] {
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
    update(root: root, isFullScreen: window.styleMask.contains(.fullScreen))
  }

  /// What `check` does, for the window's whole hierarchy under `root`.
  func update(root: NSView, isFullScreen: Bool) {
    guard isFullScreen else {
      showHidden()
      return
    }
    // Taken back by AppKit to the toolbar's window: its own place again, shown there.
    hidden.removeAll { entry in
      if let view = entry.view, view.superview is NSSplitView { return false }
      entry.view?.isHidden = false
      NotificationCenter.default.removeObserver(entry.observer)
      return true
    }
    for view in Self.strayBackgrounds(in: root) where !view.isHidden {
      view.isHidden = true
      let observer = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: view, queue: .main
      ) { [weak self] _ in
        // After the move: from the notification, the view may still be on its way.
        DispatchQueue.main.async { self?.check() }
      }
      hidden.append(Hidden(view: view, observer: observer))
    }
  }

  /// The toolbar backgrounds held by a split view under `root`: in a full-screen window, none
  /// should be, since they all belong to the toolbar's own window.
  static func strayBackgrounds(in root: NSView) -> [NSView] {
    var found: [NSView] = []
    var queue = [root]
    while !queue.isEmpty {
      let view = queue.removeFirst()
      if view is NSSplitView {
        found += view.subviews.filter {
          NSStringFromClass(type(of: $0)) == backgroundClassName
        }
        // The columns' contents hold no toolbar background: not walked.
        continue
      }
      queue += view.subviews
    }
    return found
  }

  private func showHidden() {
    for entry in hidden {
      entry.view?.isHidden = false
      NotificationCenter.default.removeObserver(entry.observer)
    }
    hidden = []
  }

  /// Shows what it hid and watches nothing more.
  func stop() {
    showHidden()
    pendingCheck?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }
}

/// Puts `FullScreenTitlebarRepair` on the window it is drawn in, and has it look again whenever
/// the columns change.
struct FullScreenTitlebarRepairReader: NSViewRepresentable {
  let columns: WorkspaceColumns

  func makeCoordinator() -> FullScreenTitlebarRepair { FullScreenTitlebarRepair() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let repair = context.coordinator
    DispatchQueue.main.async { [weak view] in
      if let window = view?.window { repair.watch(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Out of its window for a moment, it keeps watching the one it had.
    if let window = nsView.window { context.coordinator.watch(window) }
    context.coordinator.columnsChanged(to: columns)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: FullScreenTitlebarRepair) {
    coordinator.stop()
  }
}
