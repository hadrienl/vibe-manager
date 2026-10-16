import CompanionKit
import SwiftUI
import UIKit
import UserNotifications

/// Vibe Companion (#347): a debug application that proves the iPhone and the Mac reach each other
/// through CloudKit. It shows the connection, the Mac's active sessions — read only — and a test
/// button the Mac answers with an alert. In French and English only: it is not a product yet.
@main
struct VibeCompanionApp: App {
  @UIApplicationDelegateAdaptor private var delegate: CompanionAppDelegate

  var body: some Scene {
    WindowGroup {
      CompanionScreen()
        .environment(delegate.model)
        .environment(delegate.channel)
        .environment(delegate.notifications)
    }
  }
}

/// Holds the model from the very start of the launch: the sync engine must exist before the first
/// push can be delivered.
@MainActor
final class CompanionAppDelegate: NSObject, UIApplicationDelegate,
  @preconcurrency UNUserNotificationCenterDelegate
{
  let model: CompanionModel
  /// The active channel (#368), opened and closed by the screen with the foreground.
  let channel = CompanionChannel()
  /// The visible notifications of the Mac's requests (#368).
  let notifications = CompanionNotifications()

  override init() {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    model = CompanionModel(
      sync: CompanionCloudSync(
        storeURL: support.appendingPathComponent("Companion/sync.json", isDirectory: false)),
      deviceName: UIDevice.current.name)
    super.init()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Before the launch ends: a tap on a notification that launched the application is handed
    // to the delegate set by then.
    UNUserNotificationCenter.current().delegate = self
    // The engine registers for remote notifications itself; the notifications ask again once it
    // has, for the debug screen to see the token come.
    Task {
      await model.start()
      await notifications.start()
    }
    return true
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data
  ) {
    notifications.registered(tokenLength: token.count)
  }

  func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
  ) {
    notifications.registrationFailed(error)
  }

  /// A request's alert while the application is open: shown all the same, and noted.
  ///
  /// The completion-handler forms, on the main actor: the `async` ones resume UIKit off the main
  /// thread, and a tap on the alert then aborted the application in its state restoration (#368).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    note(notification)
    completionHandler([.banner, .list, .sound])
  }

  /// A tap on the alert: the application opens, which is all it asks (#368).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    note(response.notification)
    completionHandler()
  }

  private func note(_ notification: UNNotification) {
    let content = notification.request.content
    let delivery = CompanionNotifications.Delivery(
      title: content.title, body: content.body, date: notification.date)
    notifications.delivered(delivery)
  }

  /// CloudKit's silent push. The engine fetches on its own; this notes it for the debug screen.
  func application(
    _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    await model.notePush()
    return .newData
  }
}
