import AppKit
import SwiftUI
import VibeApplication
import VibeComposition
import VibeDomain
import VibePersistence
import VibeTerminal
import VibeUI

/// The one binary is two programs. Given `--terminal-host`, it is the terminal host (ADR 0017) and
/// never returns: no `NSApplication` is created, so it has no Dock icon, no menu bar and no window.
/// Being the same signed binary is the point: TCC and the host's peer check both see Vibe Manager.
@main
enum Entry {
  static func main() {
    TerminalHost.runIfRequested(diagnostics: { directory in
      Diagnostics.standard(location: DiagnosticsLocation(directory: directory), origin: .host).0
    })
    VibeManagerApp.main()
  }
}

struct VibeManagerApp: App {
  private static let troubleshooting = URL(
    string: "https://github.com/hadrienl/vibe-manager/blob/main/docs/operations.md")

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

        TemplateCommands(model: environment.appModel)
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
            ? String(localized: "Hide Context", comment: "Hides the inspector of the window.")
            : String(localized: "Show Context", comment: "Shows the inspector of the window.")
        ) {
          environment.appModel.layout.toggleInspector()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])

        // Without it the terminal keeps the keyboard, and the notes can only be reached with the
        // pointer. Escape in the notes hands the keyboard back.
        Button("Edit Notes") {
          environment.appModel.focusNotes()
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(environment.appModel.selectedSessionID == nil)

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

        Divider()

        // Between the three zones of the window, from the keyboard alone. An agent in the
        // terminal loses these three combinations, which full-screen programs rarely use.
        Button("Focus Sidebar") {
          environment.appModel.focusSidebar()
        }
        .keyboardShortcut("1", modifiers: [.command, .option])

        Button("Focus Terminal") {
          environment.appModel.focusTerminal()
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(environment.appModel.selectedSessionID == nil)

        Button("Focus Inspector") {
          environment.appModel.focusInspector()
        }
        .keyboardShortcut("3", modifiers: [.command, .option])
        .disabled(environment.appModel.selectedSessionID == nil)

        // What the terminal said last, read by VoiceOver on demand rather than as it arrives.
        Button("Read Last Output") {
          Task { await environment.appModel.readLastOutput() }
        }
        .keyboardShortcut("o", modifiers: [.command, .option, .control])
      }

      SessionHistoryCommands(model: environment.appModel, focus: windowFocus)

      // Nothing leaves the Mac from here: the sheet shows the whole file, and the user saves it.
      CommandGroup(after: .help) {
        // Known limits, and how to recover from each thing that can go wrong.
        if let troubleshooting = Self.troubleshooting {
          Link("Troubleshooting", destination: troubleshooting)
        }
        Button("Export Diagnostics…") {
          environment.appModel.beginDiagnosticsExport()
        }
        .disabled(!environment.appModel.canExportDiagnostics)
      }
    }

    Settings {
      SettingsView(permissions: environment.permissions, model: environment.appModel)
    }

    // One window, reopened rather than duplicated. SwiftUI lists it in the Window menu itself,
    // so the shortcut goes on the scene rather than on a second menu item.
    Window("Usage", id: "usage") {
      UsageWindow(model: environment.appModel)
    }
    .defaultSize(width: 820, height: 560)
    .keyboardShortcut("u", modifiers: [.command, .option])
  }
}

/// Starting a session from a template, and managing them.
///
/// ⇧⌘N opens the sheet on the first template, its fields ready to type in; the picker at the top
/// of the sheet changes it. The submenu goes straight to any of them.
private struct TemplateCommands: View {
  let model: AppModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("New Session from Template") {
      model.beginNewSession(template: model.templates.all.first?.id)
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])
    .disabled(!model.canCreateSession || model.templates.all.isEmpty)

    Menu("New Session from") {
      ForEach(model.templates.all) { template in
        Button(template.trimmedName) {
          model.beginNewSession(template: template.id)
        }
      }
    }
    .disabled(!model.canCreateSession || model.templates.all.isEmpty)

    Divider()

    Button("Manage Prompt Templates…") {
      model.settingsTab = .templates
      openSettings()
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
    guard model.sessions.indices.contains(index) else {
      return String(
        localized: "Session \(position)",
        comment: "A menu item for the session at this position in the list, when there is none.")
    }
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
      Button(
        model.selectedSession.map(model.restartTitle) ?? String(localized: "Restart Session")
      ) {
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

  /// Whether this quit is the Mac shutting down, restarting or logging out: nothing survives that,
  /// and a question on screen would hold the logout up for an answer that changes nothing.
  ///
  /// Read from the quit event itself rather than remembered from `willPowerOffNotification`: a
  /// logout another application cancels leaves that notification behind, and every later quit
  /// would have stopped the agents without asking.
  private var isPoweringOff: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    else { return false }
    return [kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].map { OSType($0) }
      .contains(reason)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let environment else { return .terminateNow }
    // Asked a second time — a quit the system retries, a quit the user repeats — the work has
    // already been done, and the reply for it has already been consumed. Another `terminateLater`
    // would wait for an answer nothing is left to send, and the application would never quit.
    guard !hasRepliedToTermination else { return .terminateNow }
    // A quit already on its way — flushing the notes, or asking about them — answers for this one.
    guard !isFlushingNotes else { return .terminateCancel }
    guard let keepingAgentsRunning = decideAboutRunningAgents(in: environment) else {
      return .terminateCancel
    }
    isFlushingNotes = true

    // Terminating immediately would orphan the process tree of every open terminal, and leave
    // the next launch without the intention to resume them. The deadline starts after the
    // question: it bounds the tidying, not the time the user takes to answer.
    Task {
      // A template being edited is saved explicitly, so quitting asks what to do with it — before
      // anything is stopped, since Cancel must leave everything as it was.
      guard await confirmTemplateChanges(environment.appModel.templates) else {
        isFlushingNotes = false
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
        return
      }
      // The notes first, and before the deadline starts: the one thing that can be lost here is
      // what the user typed, and they are asked before it is.
      // Bounded: a write stuck on a stalled volume must not keep the application from quitting.
      let unsaved = await environment.appModel.notes.flushAll(deadline: Self.notesDeadline)
      if !unsaved.isEmpty {
        let proceed = confirmQuit(losing: unsaved, names: environment.appModel.sessions)
        guard proceed else {
          isFlushingNotes = false
          NSApplication.shared.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      Task {
        try? await Task.sleep(for: Self.shutdownDeadline)
        guard !hasRepliedToTermination else { return }
        environment.diagnostics.record(.lifecycle, .error, "app.quitDeadlineReached")
        replyToTermination()
      }
      await environment.shutdown(keepingAgentsRunning: keepingAgentsRunning)
      replyToTermination()
    }
    return .terminateLater
  }

  private var isFlushingNotes = false
  /// How long quitting waits for the notes before asking about those still not on disk.
  private static let notesDeadline: Duration = .seconds(2)

  /// Changes to a prompt template are only ever lost on purpose: Save, Don't Save or Cancel, as
  /// for any document. A template that cannot be saved as it is says why, and offers only to go
  /// back to it or to quit without it.
  private func confirmTemplateChanges(_ templates: PromptTemplateLibraryModel) async -> Bool {
    guard templates.isEdited, let editing = templates.editing else { return true }
    let name =
      editing.trimmedName.isEmpty
      ? String(localized: "Untitled Template", comment: "The name of a template that has none yet.")
      : editing.trimmedName
    let alert = NSAlert()
    alert.alertStyle = .warning
    if templates.canSave {
      alert.messageText = String(
        localized: "Save the changes to the template “\(name)” before quitting?",
        comment: "The name of a prompt template.")
      alert.informativeText = String(localized: "Your changes are lost if you don't save them.")
      alert.addButton(withTitle: String(localized: "Save"))
      alert.addButton(withTitle: String(localized: "Cancel"))
      alert.addButton(withTitle: String(localized: "Don't Save")).hasDestructiveAction = true
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        // A save that fails keeps the application open, with the reason in the templates window.
        return await templates.save()
      case .alertThirdButtonReturn:
        return true
      default:
        return false
      }
    }
    let issue = templates.issues.first.map { "\($0.message) \($0.remedy)" }
    alert.messageText = String(
      localized: "The template “\(name)” has changes that can't be saved.",
      comment: "The name of a prompt template.")
    alert.informativeText =
      (issue.map { $0 + " " } ?? "")
      + String(localized: "Go back to it to finish them, or quit without them.")
    // Cancel is the default: Return must not be the key that loses what was typed.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Quit Anyway")).hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
  }

  /// Notes that could not be written are only ever lost on purpose.
  private func confirmQuit(losing unsaved: [NotesDocument], names sessions: [WorkSession]) -> Bool {
    let names = unsaved.map { document in
      sessions.first { $0.id == document.sessionID }?.name
        ?? String(localized: "a session", comment: "Stands for a session whose name is unknown.")
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      names.count == 1
      ? String(
        localized: "The notes of “\(names[0])” couldn't be saved.", comment: "A session's name.")
      : String(localized: "The notes of \(names.count) sessions couldn't be saved.")
    var reason = ""
    if case .failed(let error, _) = unsaved.first?.state {
      reason = (error.errorDescription ?? "") + " "
    }
    alert.informativeText =
      reason
      + String(
        localized: "Copy them before quitting, or what was typed since the last save is lost.")
    // Cancel is the default: Return must not be the key that loses what was typed.
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.addButton(withTitle: String(localized: "Copy Notes and Quit"))
    alert.addButton(withTitle: String(localized: "Quit Anyway")).hasDestructiveAction = true
    switch alert.runModal() {
    case .alertSecondButtonReturn:
      let text = zip(names, unsaved).map { name, document in
        unsaved.count == 1 ? document.text : "\(name)\n\n\(document.text)"
      }.joined(separator: "\n\n———\n\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      return true
    case .alertThirdButtonReturn:
      return true
    default:
      return false
    }
  }

  /// Whether to leave the agents running, or `nil` when the user cancelled the quit.
  ///
  /// Asked only when there is something to leave: an agent running in the terminal host. The
  /// answer remembered by "Don't ask again" is changed in the settings.
  private func decideAboutRunningAgents(in environment: AppEnvironment) -> Bool? {
    let count = environment.hostedRunningCount
    guard count > 0, !isPoweringOff else { return false }
    switch environment.appModel.quitBehavior {
    case .keepRunning: return true
    case .stopAll: return false
    case .ask: break
    }

    let alert = NSAlert()
    alert.messageText =
      count == 1
      ? String(localized: "An agent is still running.")
      : String(localized: "Agents are running in \(count) sessions.")
    var information = String(
      localized: """
        You can leave them working in the background and find them as they are the next time you \
        open Vibe Manager. A restart of the Mac stops them.
        """)
    let inProcess = environment.inProcessRunningCount
    if inProcess > 0 {
      information +=
        "\n\n"
        + String(
          localized: "\(inProcess) other agents run inside Vibe Manager and will stop either way.")
    }
    alert.informativeText = information
    alert.addButton(withTitle: String(localized: "Keep Running"))
    alert.addButton(withTitle: String(localized: "Stop All"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = String(localized: "Don't ask again")

    let keep: Bool
    switch alert.runModal() {
    case .alertFirstButtonReturn: keep = true
    case .alertSecondButtonReturn: keep = false
    default: return nil
    }
    if alert.suppressionButton?.state == .on {
      environment.appModel.quitBehavior = keep ? .keepRunning : .stopAll
    }
    return keep
  }

  /// Answered once, whichever of the two tasks gets here first.
  private func replyToTermination() {
    guard !hasRepliedToTermination else { return }
    hasRepliedToTermination = true
    environment?.diagnostics.flush()
    NSApplication.shared.reply(toApplicationShouldTerminate: true)
  }
}
