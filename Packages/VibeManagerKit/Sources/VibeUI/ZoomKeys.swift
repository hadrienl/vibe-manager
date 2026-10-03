import AppKit

/// View › Zoom In, Zoom Out and Actual Size, read from a key press (#229).
public enum ZoomCommand: Equatable, Sendable {
  case zoomIn, zoomOut, actualSize

  /// The zoom a key press asks for, whatever the keyboard layout: ⌘+ and ⌘= zoom in — the
  /// unshifted key of US keyboards, as in Apple's applications — ⌘− zooms out, ⌘0 comes back.
  /// The 0 is also read from its key: on a French keyboard it is ⇧à, and ⌘à means it too.
  static func matching(_ event: NSEvent) -> ZoomCommand? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
    switch event.charactersIgnoringModifiers {
    case "+", "=": return .zoomIn
    case "-": return .zoomOut
    case "0": return .actualSize
    default: return event.keyCode == Self.zeroKey ? .actualSize : nil
    }
  }

  /// The 0 key of the main row, where it is on every layout.
  static let zeroKey: UInt16 = 29
}

/// Zooms on the keys of the View menu's zoom, before any view of the window sees them (#229).
///
/// The menu shows ⌘+, ⌘− and ⌘0, but SwiftUI gives a command a single shortcut: ⌘= and the keys
/// of other layouts would do nothing, and a page of the web view keeps ⌘ keys for itself before
/// the menu is asked. One monitor of the application's key presses takes them all, so the zoom
/// answers the same over the conversation, the terminals and the web view. The floating panel of
/// the requests keeps ⌘− for itself and is left alone.
@MainActor
final class ZoomKeyMonitor {
  // Removed in `deinit`, which is not on the main actor; only ever touched there and in `install`.
  nonisolated(unsafe) private var monitor: Any?

  /// The zoom a key press asks for in that window, `nil` to let it through.
  nonisolated static func command(for event: NSEvent, in window: NSWindow?) -> ZoomCommand? {
    guard !(window is NSPanel) else { return nil }
    return ZoomCommand.matching(event)
  }

  func install(_ zoom: @escaping @MainActor (ZoomCommand) -> Void) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard let command = Self.command(for: event, in: event.window) else { return event }
      // Local monitors run on the main thread.
      MainActor.assumeIsolated { zoom(command) }
      return nil
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}
