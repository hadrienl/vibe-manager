import Foundation
import VibeApplication

/// What the user chose about the requests of background sessions (#40), kept across launches.
///
/// Each switch is stored so that a key never written reads as its default: notifications and the
/// Dock badge on, the notification saying the kind of request only, the palette left folded.
@MainActor
public final class UserDefaultsRequestPreferences: RequestPreferences {
  private enum Key {
    static let silencesNotifications = "requests.notifications.silenced.v1"
    static let notificationContent = "requests.notifications.content.v1"
    static let hidesDockBadge = "requests.dockBadge.hidden.v1"
    static let expandsPalette = "requests.palette.expandsOnRequest.v1"
  }

  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var notifiesRequests: Bool {
    get { !defaults.bool(forKey: Key.silencesNotifications) }
    set { defaults.set(!newValue, forKey: Key.silencesNotifications) }
  }

  public var notificationContent: RequestNotificationContent {
    get {
      defaults.string(forKey: Key.notificationContent).flatMap(
        RequestNotificationContent.init(rawValue:)) ?? .kind
    }
    set { defaults.set(newValue.rawValue, forKey: Key.notificationContent) }
  }

  public var showsDockBadge: Bool {
    get { !defaults.bool(forKey: Key.hidesDockBadge) }
    set { defaults.set(!newValue, forKey: Key.hidesDockBadge) }
  }

  public var expandsPaletteOnRequest: Bool {
    get { defaults.bool(forKey: Key.expandsPalette) }
    set { defaults.set(newValue, forKey: Key.expandsPalette) }
  }
}
