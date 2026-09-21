import AppKit
import SwiftUI
import VibeUI

@main
struct VibeManagerApp: App {
  @State private var environment = AppEnvironment()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView(model: environment.appModel, terminal: environment.terminalPane)
        .onAppear {
          appDelegate.environment = environment
        }
    }
    .defaultSize(width: 1_180, height: 760)

    Settings {
      Form {
        Text("Settings will be available in a future version.")
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(width: 420)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var environment: AppEnvironment?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let environment else { return .terminateNow }

    // Terminating immediately would orphan the process tree of every open terminal.
    Task {
      await environment.stopAllTerminals()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
