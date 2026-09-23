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

        Divider()

        Button("Next Scope") {
          environment.appModel.cycleScope()
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
      }

      SessionHistoryCommands(model: environment.appModel)
    }

    Settings {
      SettingsView(permissions: environment.permissions)
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

/// Restarting, closing, archiving and unarchiving the selected session, in their own menu.
///
/// ⌃⌘W rather than ⌘W: closing a session and closing the window must not be one modifier apart,
/// because one of them ends an agent's work and the other only puts a window away. ⌃⌘R joins the
/// same series, so every verb that moves a session through its life shares one modifier.
private struct SessionHistoryCommands: Commands {
  let model: AppModel

  var body: some Commands {
    CommandMenu("Session") {
      // The label follows the session: one that was created and never ran is started, not
      // restarted, and the menu is where a keyboard-only user reads which of the two this is.
      Button(model.selectedSession.map(model.restartTitle) ?? "Restart Session") {
        guard let session = model.selectedSession else { return }
        Task { await model.restart(session.id) }
      }
      .keyboardShortcut("r", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canRestart) ?? false))

      Divider()

      Button("Close Session") {
        guard let session = model.selectedSession else { return }
        Task { await model.close(session.id) }
      }
      .keyboardShortcut("w", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canClose) ?? false))

      Button("Archive…") {
        guard let session = model.selectedSession else { return }
        model.requestArchive(session.id)
      }
      .keyboardShortcut("a", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canArchive) ?? false))

      Button("Unarchive") {
        guard let session = model.selectedSession else { return }
        Task { await model.restore(session.id) }
      }
      .keyboardShortcut("a", modifiers: [.command, .control, .shift])
      .disabled(!(model.selectedSession.map(model.canRestore) ?? false))
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var environment: AppEnvironment?

  /// How long quitting may spend being tidy.
  ///
  /// The stop itself pays a three-second grace period per terminal, and this leaves room for the
  /// store writes around it. Past that the application stops waiting: an agent that ignores
  /// `SIGTERM`, and whose `SIGKILL` the kernel is slow to reap, was enough to make an application
  /// that would not quit — a worse failure than the orphan the wait was avoiding, and one the
  /// `atexit` guard of `TerminalProcessGroupGuard` catches anyway.
  private static let shutdownDeadline: Duration = .seconds(6)

  private var hasRepliedToTermination = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let environment else { return .terminateNow }
    // Asked a second time — a quit the system retries, a quit the user repeats — the work has
    // already been done, and the reply for it has already been consumed. Another `terminateLater`
    // would wait for an answer nothing is left to send, and the application would never quit.
    guard !hasRepliedToTermination else { return .terminateNow }

    // Terminating immediately would orphan the process tree of every open terminal, and leave
    // the next launch without the intention to resume them.
    Task {
      await environment.shutdown()
      replyToTermination()
    }
    Task {
      try? await Task.sleep(for: Self.shutdownDeadline)
      replyToTermination()
    }
    return .terminateLater
  }

  /// Answered once, whichever of the two tasks gets here first.
  private func replyToTermination() {
    guard !hasRepliedToTermination else { return }
    hasRepliedToTermination = true
    NSApplication.shared.reply(toApplicationShouldTerminate: true)
  }
}
