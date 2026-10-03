import AppKit
import ObjectiveC

/// Keeps the alerts and confirmation dialogs of the tests off the screen.
///
/// SwiftUI presents them as sheets, through `NSAlert.beginSheetModal(for:completionHandler:)`. On a
/// window never shown, as every test window is, AppKit puts the sheet up as a window of its own in
/// the middle of the screen, above the user's work, and asks for attention. Once installed, an alert
/// begun as a sheet is only held here, with its completion handler, until a test dismisses it.
/// Installed for the whole process: an alert no test dismisses stays held, never on screen.
@MainActor
enum HeldAlerts {
  private struct Held {
    weak var window: NSWindow?
    let alert: NSAlert
    let completion: ((NSApplication.ModalResponse) -> Void)?
  }

  private static var held: [Held] = []

  private static let installation: Void = {
    guard
      let original = class_getInstanceMethod(
        NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:))),
      let replacement = class_getInstanceMethod(
        NSAlert.self, #selector(NSAlert.holdSheetModal(for:completionHandler:)))
    else { preconditionFailure("NSAlert no longer begins its sheets by this selector") }
    method_exchangeImplementations(original, replacement)
  }()

  static func install() { _ = installation }

  /// The alert held for `window`, the last one if several were.
  static func alert(on window: NSWindow) -> NSAlert? {
    held.last { $0.window === window }?.alert
  }

  /// Answers the alert held for `window` as `endSheet` would.
  static func dismiss(on window: NSWindow) {
    guard let index = held.lastIndex(where: { $0.window === window }) else { return }
    let dismissed = held.remove(at: index)
    dismissed.completion?(.stop)
  }

  fileprivate static func hold(
    _ alert: NSAlert, on window: NSWindow,
    completion: ((NSApplication.ModalResponse) -> Void)?
  ) {
    held.removeAll { $0.window == nil }
    held.append(Held(window: window, alert: alert, completion: completion))
  }
}

extension NSAlert {
  /// Exchanged with `beginSheetModal(for:completionHandler:)` by `HeldAlerts.install()`.
  @objc fileprivate func holdSheetModal(
    for window: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?
  ) {
    HeldAlerts.hold(self, on: window, completion: completionHandler)
  }
}
