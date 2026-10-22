import CompanionCore
import CompanionKit
import SwiftUI
import UIKit
import UserNotifications

/// Vibe Companion (#347, #400): the Mac's sessions on the iPhone, driven over the direct channel,
/// with CloudKit for the Mac's address and the notifications.
@main
struct VibeCompanionApp: App {
  @UIApplicationDelegateAdaptor private var delegate: CompanionAppDelegate

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(delegate.model)
        .environment(delegate.channel)
        .environment(delegate.remote)
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
  /// The direct channel to the Mac (#399, #400).
  let remote = RemoteChannel(deviceName: UIDevice.current.name)
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
    let model = self.model
    remote.onEndpoint = { endpointID in await model.register(endpointID: endpointID) }
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

/// Opens the direct channel in the foreground and closes it in the background: iOS breaks a
/// suspended application's socket anyway. A failed channel is tried again every few seconds.
struct RootView: View {
  @Environment(CompanionModel.self) private var model
  @Environment(RemoteChannel.self) private var remote
  @Environment(CompanionNotifications.self) private var notifications
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var remote = remote
    SessionsView()
      // Here, above every screen: a failure is said wherever the user is.
      .alert(
        "The Mac Couldn’t Do It",
        isPresented: Binding(
          get: { remote.failure != nil }, set: { if !$0 { remote.failure = nil } })
      ) {
        Button("OK", role: .cancel) { /* The alert dismisses itself. */ }
      } message: {
        Text(verbatim: remote.failure?.text ?? "")
      }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(10))
          await model.refresh()
          await notifications.refresh()
        }
      }
      .task(id: remote.phase) {
        guard case .failed = remote.phase else { return }
        try? await Task.sleep(for: .seconds(5))
        if scenePhase == .active { remote.open(to: model.selectedMac) }
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .active:
          Task { await model.refresh() }
          if remote.phase != .connecting && remote.phase != .connected {
            remote.open(to: model.selectedMac)
          }
        case .background:
          remote.close()
        default:
          break
        }
      }
      .onChange(of: model.selectedMac?.irohEndpointID, initial: true) { _, _ in
        if scenePhase == .active { remote.open(to: model.selectedMac) }
      }
  }
}

extension RemoteFailure {
  /// What went wrong, in the phone's language; the Mac's own words when it gave them.
  var text: String {
    switch self {
    case .sessionGone: String(localized: "This session no longer exists on the Mac.")
    case .messageNotSent:
      String(localized: "The message couldn’t be sent: the agent isn’t running.")
    case .requestGone: String(localized: "This request no longer waits for an answer.")
    case .answerNotGiven: String(localized: "The answer couldn’t be given. Answer on the Mac.")
    case .restartNeedsMac:
      String(
        localized:
          "The Mac can’t resume this conversation and asks what to do. Answer on the Mac.")
    case .folderMissing: String(localized: "This folder doesn’t exist on the Mac.")
    case .noAgent: String(localized: "The Mac knows no agent.")
    case .other(let words): words
    }
  }
}
