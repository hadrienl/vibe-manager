/// How much of a request a system notification says (#40).
public enum RequestNotificationContent: String, Hashable, Sendable, CaseIterable {
  /// The session and the kind of request: "Permission requested: shell command". Nothing the
  /// agent wrote — a lock screen or a shared screen shows no command.
  case kind
  /// The command, the file or the question itself. Hidden on the lock screen all the same.
  case detail
}

/// What the user chose about the requests of background sessions (#40).
@MainActor
public protocol RequestPreferences: AnyObject {
  /// A system notification when a request arrives while the application is in the background.
  var notifiesRequests: Bool { get set }
  var notificationContent: RequestNotificationContent { get set }
  /// The number of pending requests on the application's icon in the Dock.
  var showsDockBadge: Bool { get set }
  /// A request arriving unfolds a folded palette.
  var expandsPaletteOnRequest: Bool { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryRequestPreferences: RequestPreferences {
  public var notifiesRequests: Bool
  public var notificationContent: RequestNotificationContent
  public var showsDockBadge: Bool
  public var expandsPaletteOnRequest: Bool

  public init(
    notifiesRequests: Bool = true,
    notificationContent: RequestNotificationContent = .kind,
    showsDockBadge: Bool = true,
    expandsPaletteOnRequest: Bool = false
  ) {
    self.notifiesRequests = notifiesRequests
    self.notificationContent = notificationContent
    self.showsDockBadge = showsDockBadge
    self.expandsPaletteOnRequest = expandsPaletteOnRequest
  }
}
