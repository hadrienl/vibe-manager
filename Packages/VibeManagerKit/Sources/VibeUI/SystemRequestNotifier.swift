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
  /// The system's question, while it is on screen: posts waiting on it share its answer.
  private var authorization: Task<Bool, Never>?
  /// The notifications posted and not taken away since. One taken away while it was still on its
  /// way — its request answered while the system asked about notifications — must not arrive.
  private var wanted: Set<String> = []

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
    let identifier = Self.identifier(of: notification.id)
    wanted.insert(identifier)
    Task {
      guard await authorized(), wanted.contains(identifier) else { return }
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
      deliver(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
  }

  /// Adds it, with a handler: the center is not `Sendable` in every SDK the application is built
  /// with, and is only called here, on the main actor.
  private func deliver(_ request: UNNotificationRequest) {
    let identifier = request.identifier
    center.add(request) { [weak self] _ in
      Task { @MainActor in self?.withdrawIfUnwanted(identifier) }
    }
  }

  /// Taken away while it was being added: it must not stay.
  private func withdrawIfUnwanted(_ identifier: String) {
    guard !wanted.contains(identifier) else { return }
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
  }

  public func remove(_ ids: [AgentRequestID]) {
    let identifiers = ids.map(Self.identifier(of:))
    wanted.subtract(identifiers)
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  public func setBadge(_ count: Int?) {
    NSApp?.dockTile.badgeLabel = count.map(String.init)
  }

  public func isAuthorized() async -> Bool? {
    switch await authorizationStatus() {
    case .notDetermined: return nil
    case .denied: return false
    default: return true
    }
  }

  /// What the system allows now: notifications turned on in System Settings after a refusal
  /// count from the next request, without a relaunch. The question itself is asked once.
  private func authorized() async -> Bool {
    switch await authorizationStatus() {
    case .denied: return false
    case .notDetermined: break
    default: return true
    }
    if let authorization { return await authorization.value }
    let task = Task { await self.requestAuthorization() }
    authorization = task
    let granted = await task.value
    authorization = nil
    return granted
  }

  /// The center is not `Sendable` in every SDK the application is built with: it is only called
  /// here, on the main actor, with handlers.
  private func requestAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        continuation.resume(returning: granted)
      }
    }
  }

  /// Only the status leaves the handler: the settings themselves are not `Sendable` in every SDK
  /// the application is built with.
  private func authorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      center.getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
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
