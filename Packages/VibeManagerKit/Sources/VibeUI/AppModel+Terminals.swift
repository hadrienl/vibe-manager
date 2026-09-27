import AppKit
import Foundation
import VibeApplication
import VibeDomain

/// A side terminal the user asked to close while a command runs in it (#43).
public struct PendingTerminalClose: Equatable, Sendable {
  public let sessionID: SessionID
  public let terminalID: TerminalID
  public let command: String
}

/// The drawer of side terminals of the session on screen (#43), as the menus and the window drive
/// it.
extension AppModel {
  /// The drawer of the session on screen, when that session can have one: an active session.
  /// A closed or archived session's side terminals are stopped, and come back when it reopens.
  public var selectedDrawer: SessionTerminalDrawer? {
    guard let session = selectedSession, canUseDrawer(session) else { return nil }
    return terminals?.drawer(for: session.id)
  }

  public func canUseDrawer(_ session: WorkSession) -> Bool {
    terminals != nil && session.status == .active
  }

  /// Show Terminals / Hide Terminals.
  public var canToggleDrawer: Bool {
    selectedDrawer != nil
  }

  public var isDrawerShown: Bool {
    guard let drawer = selectedDrawer else { return false }
    return drawer.isVisible && !drawer.terminals.isEmpty
  }

  /// ⌘J, and the button of the status bar.
  public func toggleDrawer() {
    guard let drawer = selectedDrawer else { return }
    let wasShown = isDrawerShown
    Task {
      await drawer.toggle()
      // The keyboard leaves a drawer put away for the agent — its terminal, or the composer of
      // its conversation — not for nothing.
      if wasShown { focusSessionContent() }
    }
  }

  /// ⌘T: a new tab, the drawer shown if it was not.
  public var canAddDrawerTerminal: Bool {
    selectedDrawer?.canAddTerminal ?? false
  }

  public func newDrawerTerminal() {
    guard let drawer = selectedDrawer else { return }
    Task { await drawer.newTerminal() }
  }

  /// ⌘⌥5: the keyboard to the terminal in front of the drawer, shown if it was not.
  public func focusDrawer() {
    guard let drawer = selectedDrawer else { return }
    Task {
      if !(drawer.isVisible && !drawer.terminals.isEmpty) {
        await drawer.show()
      }
      drawer.requestFocus()
    }
  }

  /// Whether ⌘W closes a side terminal: the keyboard is in the drawer, and a tab is in front.
  public var closesDrawerTerminal: Bool {
    guard let drawer = selectedDrawer else { return false }
    return drawer.isFocused && drawer.activeTerminal != nil
  }

  /// Whether ⌃⇥ moves through the drawer's tabs rather than the web view's.
  public var movesThroughDrawerTabs: Bool {
    guard let drawer = selectedDrawer else { return false }
    return drawer.isFocused && drawer.terminals.count > 1
  }

  public func selectNextDrawerTerminal() {
    selectedDrawer?.activateNeighbour(offset: 1)
  }

  public func selectPreviousDrawerTerminal() {
    selectedDrawer?.activateNeighbour(offset: -1)
  }

  /// Closes a side terminal, or asks first when a command runs in its foreground: a dev server,
  /// a build, an editor with unsaved work.
  public func requestCloseDrawerTerminal(_ id: TerminalID? = nil) {
    guard let drawer = selectedDrawer,
      let terminal = drawer.terminals.first(where: { $0.id == (id ?? drawer.activeTerminalID) })
    else {
      NSSound.beep()
      return
    }
    Task {
      if let command = await drawer.runningCommand(of: terminal.id) {
        pendingTerminalClose = PendingTerminalClose(
          sessionID: drawer.sessionID, terminalID: terminal.id, command: command)
        return
      }
      await drawer.close(terminal.id)
    }
  }

  public func cancelCloseDrawerTerminal() {
    pendingTerminalClose = nil
  }

  /// Closes the terminal the confirmation was opened for. Takes the value rather than reading
  /// `pendingTerminalClose`: the dialog is dismissed, and it cleared, before the button runs.
  public func confirmCloseDrawerTerminal(_ pending: PendingTerminalClose) {
    pendingTerminalClose = nil
    guard let drawer = terminals?.existingDrawer(for: pending.sessionID) else { return }
    Task { await drawer.close(pending.terminalID) }
  }

  /// The commands running in a session's side terminals, which closing the session stops.
  public func runningDrawerCommands(of id: SessionID) -> [String] {
    terminals?.existingDrawer(for: id)?.terminals
      .filter(\.isRunningCommand).compactMap(\.foregroundCommand) ?? []
  }
}
