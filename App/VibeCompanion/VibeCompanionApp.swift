import CompanionKit
import SwiftUI
import UIKit

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
    }
  }
}

/// Holds the model from the very start of the launch: the sync engine must exist before the first
/// push can be delivered.
@MainActor
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
  let model: CompanionModel

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
    // The engine registers for remote notifications itself; registering here too would hand it
    // the token twice.
    Task { await model.start() }
    return true
  }

  /// CloudKit's silent push. The engine fetches on its own; this notes it for the debug screen.
  func application(
    _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    await model.notePush()
    return .newData
  }
}
