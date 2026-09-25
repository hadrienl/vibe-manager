import AppKit

/// Says something to VoiceOver, now, without moving the focus.
@MainActor
public enum Announcer {
  /// What was last announced. For tests: an announcement leaves no other trace.
  public private(set) static var lastAnnouncement: String?

  public static func announce(_ text: String) {
    lastAnnouncement = text
    let element: Any = NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp as Any
    NSAccessibility.post(
      element: element,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}
