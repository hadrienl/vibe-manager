import AppKit
import UserNotifications
import VibeApplication
import VibeDomain

/// The requests of background sessions in the Notification Center and on the Dock icon (#40).
///
/// Created by the application only: the notification center needs a bundle, which the package's
/// tests do not have. Permission to notify is asked with the first notification, not at launch.
///
/// A permission can be allowed or refused from the notification itself. Allow asks to unlock the
/// Mac first on the lock screen, and is offered only for a request answerable from outside and
/// shown in full; either way the answer goes through the same checks as the palette's, and is not
/// typed if the request has gone meanwhile.
@MainActor
public final class SystemRequestNotifier: NSObject, RequestNotifying {
  static let permissionCategory = "vibe.request.permission"
  static let refusalCategory = "vibe.request.refusal"
  static let questionCategory = "vibe.request.question"
  static let allowAction = "vibe.request.allow"
  static let refuseAction = "vibe.request.refuse"
  nonisolated static let sessionKey = "session"
  nonisolated static let requestKey = "request"

  private let center: UNUserNotificationCenter
  private weak var model: AppModel?
  private var authorization: Task<Bool, Never>?

  public init(model: AppModel, center: UNUserNotificationCenter = .current()) {
    self.model = model
    self.center = center
    super.init()
    center.delegate = self
    center.setNotificationCategories(Self.categories())
  }

  static func categories() -> Set<UNNotificationCategory> {
    let allow = UNNotificationAction(
      identifier: allowAction,
      title: String(localized: LocalizedStringResource("Allow", bundle: .module)),
      options: [.authenticationRequired])
    let refuse = UNNotificationAction(
      identifier: refuseAction,
      title: String(localized: LocalizedStringResource("Refuse", bundle: .module)),
      options: [.destructive])
    // What a lock screen, or a screen being shared, says in place of the request.
    let placeholder = String(
      localized: LocalizedStringResource(
        "An agent is asking for something", bundle: .module,
        comment: "A notification whose details are hidden, on the lock screen."))
    return [
      UNNotificationCategory(
        identifier: permissionCategory, actions: [allow, refuse], intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: placeholder),
      UNNotificationCategory(
        identifier: refusalCategory, actions: [refuse], intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: placeholder),
      UNNotificationCategory(
        identifier: questionCategory, actions: [], intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: placeholder),
    ]
  }

  public func post(_ notification: RequestNotification) {
    Task {
      guard await authorized() else { return }
      let content = UNMutableNotificationContent()
      content.title = notification.title
      content.body = notification.body
      content.sound = .default
      content.threadIdentifier = notification.id.sessionID.rawValue.uuidString
      content.categoryIdentifier =
        notification.offersAllow
        ? Self.permissionCategory
        : notification.offersDeny ? Self.refusalCategory : Self.questionCategory
      content.userInfo = [
        Self.sessionKey: notification.id.sessionID.rawValue.uuidString,
        Self.requestKey: notification.id.key,
      ]
      try? await center.add(
        UNNotificationRequest(
          identifier: Self.identifier(of: notification.id), content: content, trigger: nil))
    }
  }

  public func remove(_ ids: [AgentRequestID]) {
    let identifiers = ids.map(Self.identifier(of:))
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  public func setBadge(_ count: Int?) {
    NSApp?.dockTile.badgeLabel = count.map(String.init)
  }

  public func isAuthorized() async -> Bool? {
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: return nil
    case .denied: return false
    default: return true
    }
  }

  /// Asked once, with the first notification.
  private func authorized() async -> Bool {
    if let authorization { return await authorization.value }
    let center = center
    let task = Task {
      (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    authorization = task
    return await task.value
  }

  static func identifier(of id: AgentRequestID) -> String {
    "\(id.sessionID.rawValue.uuidString)|\(id.key)"
  }

  nonisolated static func requestID(from userInfo: [AnyHashable: Any]) -> AgentRequestID? {
    guard let session = (userInfo[sessionKey] as? String).flatMap(UUID.init(uuidString:)),
      let key = userInfo[requestKey] as? String
    else { return nil }
    return AgentRequestID(sessionID: SessionID(rawValue: session), key: key)
  }

  fileprivate func respond(to action: String, for id: AgentRequestID) async {
    guard let model else { return }
    switch action {
    case Self.allowAction:
      await model.answer(.allowOnce, to: id)
    case Self.refuseAction:
      await model.answer(.deny, to: id)
    default:
      // A click on the notification itself: the palette shows the request, the session on
      // screen stays.
      NSApp.activate()
      model.revealRequest(id)
    }
  }
}

extension SystemRequestNotifier: UNUserNotificationCenterDelegate {
  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    guard let id = Self.requestID(from: response.notification.request.content.userInfo) else {
      return
    }
    await respond(to: action, for: id)
  }

  /// In front, the palette says it already.
  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }
}
