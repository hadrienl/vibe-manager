import AppKit
import SwiftUI
import VibeUI

@main
struct VibeManagerApp: App {
  @State private var environment = AppEnvironment()
  @State private var windowFocus = WindowFocus()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      RootView(model: environment.appModel)
        .onAppear {
          appDelegate.environment = environment
        }
        .background(WorkspaceWindowReader(focus: windowFocus))
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

      // SwiftUI's own Close sits here on ⌘W, which now belongs to the session. The window keeps
      // a way out one modifier further, as in Terminal and Safari.
      CommandGroup(replacing: .saveItem) {
        Button("Close Window") {
          windowFocus.closeKeyWindow()
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(windowFocus.front == .none || windowFocus.front == .sheet)
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

      SessionHistoryCommands(model: environment.appModel, focus: windowFocus)
    }

    Settings {
      SettingsView(permissions: environment.permissions, model: environment.appModel)
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
/// Close Session is ⌘W. It used to be ⌃⌘W, to keep it one modifier away from closing the window,
/// on the grounds that one ends an agent's work and the other only puts a window away. In practice
/// the sessions are this window's tabs and ⌘W is the reflex for "done with this one": the accident
/// was the window vanishing with every agent still running behind it. The agent is now protected
/// by a confirmation instead of by an awkward shortcut, and the window moved to ⇧⌘W.
///
/// ⌘W never falls back to closing the window. With nothing to close it is disabled and beeps: a
/// key that closes a session or the window depending on a state nobody can see is worse than
/// either. The other verbs keep ⌃⌘, so every one that moves a session through its life but the
/// most common shares one modifier.
private struct SessionHistoryCommands: Commands {
  let model: AppModel
  let focus: WindowFocus

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

      // Another agent or another model for the same work. Offered on a running session too: the
      // sheet says the agent will be stopped, and nothing is stopped before it is confirmed.
      Button("Switch Agent…") {
        guard let session = model.selectedSession else { return }
        model.beginAgentSwitch(session.id)
      }
      .keyboardShortcut("m", modifiers: [.command, .control])
      .disabled(!(model.selectedSession.map(model.canSwitchAgent) ?? false))

      Divider()

      Button("Close Session") {
        // Over Settings or any other window, ⌘W keeps closing that window.
        guard focus.front == .workspace else {
          focus.closeKeyWindow()
          return
        }
        guard let session = model.selectedSession else { return }
        Task { await model.requestClose(session.id) }
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(!isCloseEnabled)

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

  /// A sheet over the workspace keeps ⌘W to itself, so the session behind it is never closed.
  private var isCloseEnabled: Bool {
    switch focus.front {
    case .other: return true
    case .workspace: return model.selectedSession.map(model.canClose) ?? false
    case .sheet, .none: return false
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
