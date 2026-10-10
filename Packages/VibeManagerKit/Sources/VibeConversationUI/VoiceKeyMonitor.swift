import AppKit
import SwiftUI

/// Space as the microphone (#357): pressed, it listens; let go of, a short press starts or ends
/// the discussion, a long one inserts what was dictated — but only where Space types nothing: not
/// in a field being written, the terminal or the web view. Escape ends a discussion wherever the
/// keyboard is. One monitor, installed by the conversation on screen, for its own window.
@MainActor
final class VoiceKeyMonitor {
  private var monitor: Any?
  private var isSpaceDown = false
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
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      // Called on the main thread: only whether the event is taken leaves the main actor.
      let isTaken = MainActor.assumeIsolated { self?.handle(event, actions) ?? false }
      return isTaken ? nil : event
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
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
    if isSpaceDown { return true }
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
    let name = String(describing: type(of: responder))
    return name.contains("Terminal") || name.contains("WKWebView") || name.contains("WKContent")
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
