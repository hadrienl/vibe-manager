import AppKit
import VibeComposition
import VibeTerminal

/// One application per data directory (#436): a second one launched on the same data says so and
/// leaves, before it has composed anything — before it could take the first one's web view socket
/// or reach its terminal host.
enum SingleInstance {
  /// Held for the whole life of the process.
  nonisolated(unsafe) private static var lock: ApplicationInstanceLock?

  @MainActor static func claim() {
    switch ApplicationInstanceLock.acquire(at: AppEnvironment.hostLocation()) {
    case .acquired(let held):
      lock = held
    case .held(let holder):
      refuse(holder: holder)
    case nil:
      break
    }
  }

  @MainActor private static func refuse(holder: pid_t?) -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
      localized: "Vibe Manager is already running with this data.",
      comment: "Title of the alert shown when a second copy is launched on the same data.")
    alert.informativeText = String(
      localized:
        "Only one copy can use the same sessions. To run another copy beside it, launch it with VIBE_DATA_DIRECTORY set to a folder of its own.",
      comment:
        "Body of the alert shown when a second copy is launched on the same data. VIBE_DATA_DIRECTORY is an environment variable, not translated."
    )
    alert.addButton(withTitle: String(localized: "Quit", comment: "Closes the second copy."))
    alert.runModal()
    // The copy already running, by its process: never by bundle identifier, which a test copy shares.
    if let holder, holder != getpid() {
      NSRunningApplication(processIdentifier: holder)?.activate()
    }
    exit(0)
  }
}
