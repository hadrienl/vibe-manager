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
        Button(
          environment.appModel.layout.columns.isInspectorVisible
            ? "Hide Context" : "Show Context"
        ) {
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

/// ⌘1…⌘9, one menu item per position rather than one per session.
///
/// The items are fixed and only their labels follow the list: a menu that SwiftUI has not
/// rebuilt since a session was created or renamed then shows a stale name, where a menu built
/// from the sessions themselves would run the wrong one. `select(position:)` reads the list when
/// it is pressed, and does nothing when nobody is listed at that position.
private struct SessionPositionCommands: View {
  let model: AppModel

  var body: some View {
    ForEach(1...AppModel.shortcutPositionLimit, id: \.self) { position in
      Button(label(for: position)) {
        model.select(position: position)
      }
      .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
      .disabled(model.sessions.count < position)
    }
  }

  private func label(for position: Int) -> String {
    let index = position - 1
    guard model.sessions.indices.contains(index) else { return "Session \(position)" }
    return model.sessions[index].name
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
