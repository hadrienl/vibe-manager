import AppKit
import Observation
import SwiftUI

/// Which window ⌘W is talking to.
///
/// The menu is the same for every window, but ⌘W is not: over the workspace it closes the selected
/// session, over any other window — Settings, later the floating HITL panel — it closes that
/// window, and over a sheet it does nothing, so the session behind a dialog is never the one closed.
@MainActor
@Observable
final class WindowFocus {
  enum Front: Equatable {
    /// The workspace window itself holds the keyboard.
    case workspace
    /// A sheet or a dialog of the workspace does.
    case sheet
    /// Another window of the application does.
    case other
    /// No window of the application does.
    case none
  }

  private(set) var front: Front = .none

  @ObservationIgnored private weak var workspaceWindow: NSWindow?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
  }

  func attach(_ window: NSWindow?) {
    workspaceWindow = window
    refresh()
  }

  /// Brings the workspace window forward and gives it the keyboard: Open Quickly from Settings.
  func showWorkspace() {
    workspaceWindow?.makeKeyAndOrderFront(nil)
  }

  /// Closes the window that holds the keyboard, whichever it is: what ⇧⌘W does everywhere, and
  /// what ⌘W does over a window that is not the workspace.
  func closeKeyWindow() {
    NSApp.keyWindow?.performClose(nil)
  }

  private func refresh() {
    guard let key = NSApp.keyWindow else {
      front = .none
      return
    }
    if key === workspaceWindow {
      front = .workspace
    } else if key.sheetParent != nil {
      front = .sheet
    } else {
      front = .other
    }
  }
}

/// Hands the window a view is drawn in to `WindowFocus`, once it has one.
struct WorkspaceWindowReader: NSViewRepresentable {
  let focus: WindowFocus

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in focus.attach(view?.window) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if nsView.window != nil {
      DispatchQueue.main.async { [weak nsView] in focus.attach(nsView?.window) }
    }
  }
}
