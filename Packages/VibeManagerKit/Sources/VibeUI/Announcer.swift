import AppKit

/// Says something to VoiceOver, now, without moving the focus.
@MainActor
public enum Announcer {
  /// What was last announced. For tests: an announcement leaves no other trace.
  public private(set) static var lastAnnouncement: String?
  /// The floating panel, while it is on screen (#41): what speaks when the application is not the
  /// active one, and has no window in front.
  static weak var floatingElement: NSWindow?

  public static func announce(_ text: LocalizedStringResource) {
    announce(String(localized: text))
  }

  public static func announce(_ text: String) {
    lastAnnouncement = text
    let floating = NSApp?.isActive == false ? floatingElement : nil
    let element: Any = floating ?? NSApp?.keyWindow ?? NSApp?.mainWindow ?? NSApp as Any
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
