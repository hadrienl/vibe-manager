import AppKit
import SwiftUI
import VibeUI

@main
struct VibeManagerApp: App {
  @State private var environment = AppEnvironment()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView(model: environment.appModel)
        .onAppear {
          appDelegate.environment = environment
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Session") {
          environment.appModel.beginNewSession()
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!environment.appModel.canCreateSession)
      }

      // In the menus rather than bound to the views: a shortcut that only works while a
      // particular view holds focus is a shortcut nobody can rely on, and the menu is also
      // where VoiceOver and the keyboard-only user find these actions at all.
      CommandGroup(after: .sidebar) {
        Button("Show Context") {
          environment.appModel.layout.toggleInspector()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])

        Divider()

        Button("Next Session") {
          environment.appModel.selectNext()
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])

        Button("Previous Session") {
          environment.appModel.selectPrevious()
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])

        SessionPositionCommands(model: environment.appModel)

        Divider()
      }
    }

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

/// One menu item per listed session, for ⌘1…⌘9.
///
/// Ten and beyond get no shortcut rather than a second modifier nobody would guess: past nine
/// parallel tasks, the sidebar and its arrow keys are the honest way around.
private struct SessionPositionCommands: View {
  let model: AppModel

  var body: some View {
    ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
      Button(session.name) {
        model.select(position: index + 1)
      }
      .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
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
