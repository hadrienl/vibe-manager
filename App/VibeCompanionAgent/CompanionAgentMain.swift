import AppKit
import Security
import os

/// `Vibe Manager Companion.app`: an application without a Dock icon (`LSUIElement`), because a
/// CloudKit push is delivered to an application, never to a service (#347). The application starts
/// it from its bundle's `Contents/Helpers`, with the link's socket and the folder of its state.
@main
enum CompanionAgentMain {
  @MainActor
  static func main() {
    guard let arguments = CompanionAgent.Arguments(CommandLine.arguments) else {
      Logger(subsystem: "eu.hadrien.VibeManager.companion", category: "agent")
        .error("started without --link and --state: Vibe Manager starts it, not the user")
      exit(64)
    }
    // A build signed ad hoc — CI's interface test, a contributor without the team — cannot hold
    // the entitlement, and CloudKit would end the process on its first call: it leaves first.
    guard holdsCloudKit() else {
      Logger(subsystem: "eu.hadrien.VibeManager.companion", category: "agent")
        .error("no CloudKit entitlement in this build: the companion stays off")
      exit(0)
    }
    let application = NSApplication.shared
    let delegate = CompanionAgentDelegate(agent: CompanionAgent(arguments: arguments))
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

/// Whether this process was signed with CloudKit among its iCloud services.
private func holdsCloudKit() -> Bool {
  guard let task = SecTaskCreateFromSelf(nil) else { return false }
  let services = SecTaskCopyValueForEntitlement(
    task, "com.apple.developer.icloud-services" as CFString, nil)
  return (services as? [String])?.contains("CloudKit") == true
}

@MainActor
final class CompanionAgentDelegate: NSObject, NSApplicationDelegate {
  private let agent: CompanionAgent

  init(agent: CompanionAgent) {
    self.agent = agent
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The sync engine first, as early as possible: from then on it listens to pushes and to its
    // own scheduler. It registers for remote notifications itself.
    Task { await agent.start() }
  }

  /// CloudKit's push, which the sync engine handles on its own: only noted for the journal.
  func application(
    _ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    Task { await agent.sync.notePush() }
  }

  /// Whatever the way out — the link closed, a logout — the Mac is said offline first.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await agent.depart()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
