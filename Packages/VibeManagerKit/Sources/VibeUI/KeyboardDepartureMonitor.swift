import AppKit
import SwiftUI

/// Behind the sidebar's list, says when the window's keyboard goes somewhere other than the list
/// or the sidebar's search field (#128).
///
/// Read from the window's first responder rather than from SwiftUI's focus: in the application's
/// window, the sidebar's `@FocusState` stayed true while the keyboard was in a terminal — an
/// AppKit view — and a selection of several sessions survived there, for ⌘W to close them all.
/// Any view that takes the keyboard — the terminal, the web view, the notes, the composer, a
/// field — is seen the same way: the window says who has it.
struct KeyboardDepartureMonitor: NSViewRepresentable {
  /// Called each time the keyboard moves somewhere other than the list or the search field.
  var departed: () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.departed = departed
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.departed = departed
  }

  final class MonitorView: NSView {
    var departed: (() -> Void)?
    /// How many moves of the keyboard it has looked at, for the tests to wait on.
    private(set) var movesSeen = 0
    private var observation: NSKeyValueObservation?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
        // After the change rather than inside it: a view can move the keyboard in the middle of
        // SwiftUI's update, which is no time to change what the views read. Checked again then,
        // for a keyboard that has come back meanwhile.
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.reportIfDeparted() }
        }
      }
    }

    private func reportIfDeparted() {
      movesSeen += 1
      guard let window, !holdsKeyboard(window.firstResponder) else { return }
      departed?()
    }

    /// The list this view stands behind: beside it, in the hosting view they share. None while
    /// the list is not mounted — the keyboard is then nowhere in it.
    var list: NSTableView? {
      guard let host = superview, let container = host.superview else { return nil }
      return container.subviews.lazy.filter { $0 !== host }.compactMap(Self.table(in:)).first
    }

    /// The pane of the split view the list is drawn in: the sidebar, with its search field.
    private var column: NSView? {
      var view: NSView = self
      while let parent = view.superview {
        if parent is NSSplitView { return view }
        view = parent
      }
      return nil
    }

    /// Whether the responder is the list, a field in one of its rows, or the sidebar's search
    /// field. Told by where the view sits among the window's views, not by where it is drawn:
    /// the request palette at the foot of the sidebar can cover the list, and its field is not
    /// the list. A search keeps the selection, which it only prunes of the rows it hides (#77).
    private func holdsKeyboard(_ responder: NSResponder?) -> Bool {
      guard var view = responder as? NSView, view.window === window else { return false }
      // A field being typed into hands the keyboard to the window's field editor: the field is
      // what it edits.
      if let editor = view as? NSTextView, editor.isFieldEditor,
        let field = editor.delegate as? NSView
      {
        view = field
      }
      if let list, view.isDescendant(of: list.enclosingScrollView ?? list) { return true }
      if view is NSSearchField, let column, view.isDescendant(of: column) { return true }
      return false
    }

    private static func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      return view.subviews.lazy.compactMap(table(in:)).first
    }
  }
}
