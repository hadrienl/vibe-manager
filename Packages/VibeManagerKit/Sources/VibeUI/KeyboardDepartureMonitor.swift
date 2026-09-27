import AppKit
import SwiftUI

/// Behind a list, says when the window's keyboard goes somewhere else (#128).
///
/// Read from the window's first responder rather than from SwiftUI's focus: in the application's
/// window, the sidebar's `@FocusState` stayed true while the keyboard was in a terminal — an
/// AppKit view — and a selection of several sessions survived there, for ⌘W to close them all.
/// Any view that takes the keyboard — the terminal, the web view, the notes, the composer, a
/// field — is seen the same way: the window says who has it.
struct KeyboardDepartureMonitor: NSViewRepresentable {
  /// Called each time the keyboard moves somewhere other than the list.
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
      guard let window, !holdsKeyboard(window.firstResponder) else { return }
      departed?()
    }

    /// Whether the responder is the list this view stands behind, or a field in one of its rows.
    /// This view is the list's background, beside it rather than above it: the list is the scroll
    /// view drawn where this view is.
    private func holdsKeyboard(_ responder: NSResponder?) -> Bool {
      guard let responder = responder as? NSView, responder.window === window else { return false }
      let frame = convert(bounds, to: nil)
      // Not laid out yet: nothing can be told, and nothing is taken from the selection for it.
      guard !frame.isEmpty else { return true }
      let area = responder.enclosingScrollView ?? responder
      return area.convert(area.bounds, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY))
    }
  }
}
