import AppKit
import SwiftUI
import WebKit

/// Space as the microphone (#357): pressed, it listens; let go of, a short press starts or ends
/// the discussion, a long one inserts what was dictated — but only where Space types nothing: not
/// in a field being written, the terminal or the web view. Escape ends a discussion wherever the
/// keyboard is. One monitor, installed by the conversation on screen, for its own window.
@MainActor
final class VoiceKeyMonitor {
  private var monitor: Any?
  private var resignObserver: (any NSObjectProtocol)?
  private var isSpaceDown = false
  private var actions: Actions?
  private weak var window: NSWindow?

  struct Actions {
    var press: () -> Void
    var release: () -> Void
    /// Returns whether Escape was used: a discussion ended.
    var escape: () -> Bool
  }

  func start(in window: NSWindow?, _ actions: Actions) {
    stop()
    self.window = window
    self.actions = actions
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      // Called on the main thread: only whether the event is taken leaves the main actor.
      let isTaken = MainActor.assumeIsolated { self?.handle(event, actions) ?? false }
      return isTaken ? nil : event
    }
    // Space held while the window loses the keyboard never sees its keyUp: let go of all the same.
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isSpaceDown else { return }
        self.isSpaceDown = false
        self.actions?.release()
      }
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    isSpaceDown = false
  }

  private static let space: UInt16 = 49
  private static let escape: UInt16 = 53

  /// Whether the event was the microphone's, and is to go no further.
  private func handle(_ event: NSEvent, _ actions: Actions) -> Bool {
    guard let window, event.window === window else { return false }
    if event.keyCode == Self.escape, event.type == .keyDown {
      return actions.escape()
    }
    guard event.keyCode == Self.space else { return false }
    if event.type == .keyUp {
      guard isSpaceDown else { return false }
      isSpaceDown = false
      actions.release()
      return true
    }
    // Held, the key repeats: the press goes on.
    if event.isARepeat { return isSpaceDown }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers.isEmpty, !Self.typesSpace(window.firstResponder) else { return false }
    isSpaceDown = true
    actions.press()
    return true
  }

  /// Where Space is a character, or a key of the agent's: a field being written, the terminal,
  /// the web view.
  private static func typesSpace(_ responder: NSResponder?) -> Bool {
    guard let responder else { return false }
    if let text = responder as? NSTextView, text.isEditable { return true }
    // A page — its own fields, or keys it listens to — has the keyboard: the web view, or one of
    // its subviews.
    if let view = responder as? NSView,
      sequence(first: view, next: \.superview).contains(where: { $0 is WKWebView })
    {
      return true
    }
    let name = String(describing: type(of: responder))
    return name.contains("Terminal")
  }
}

/// The window a view is in, for the key monitor to listen to that one only.
struct WindowReader: NSViewRepresentable {
  let found: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in found(view?.window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { [weak view] in found(view?.window) }
  }
}
