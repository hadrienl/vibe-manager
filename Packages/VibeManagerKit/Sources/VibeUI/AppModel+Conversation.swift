import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain

extension AppModel {
  /// How the session is shown: what the user chose for it, or the default of the settings —
  /// and the terminal, whatever was chosen, when its agent writes nothing the view can read.
  public func presentation(of session: WorkSession) -> SessionPresentation {
    guard conversations.canShowConversation(session) else { return .terminal }
    return layout.presentation(
      of: session.id, default: conversations.appearance.defaultPresentation)
  }

  public func setPresentation(_ presentation: SessionPresentation, of id: SessionID) {
    layout.setPresentation(
      presentation, of: id, default: conversations.appearance.defaultPresentation)
    if presentation == .terminal {
      pane(for: id)?.requestFocus()
    } else {
      conversations.existingModel(for: id)?.focusComposerRequest += 1
    }
  }

  /// View › Show Conversation / Show Terminal (⌥⌘T), for the selected session.
  public func togglePresentation() {
    guard let session = selectedSession, conversations.canShowConversation(session) else { return }
    setPresentation(
      presentation(of: session) == .conversation ? .terminal : .conversation,
      of: session.id)
  }

  public var canTogglePresentation: Bool {
    selectedSession.map(conversations.canShowConversation) ?? false
  }

  /// Hooks each conversation model up to its session's terminal.
  func connectConversations() {
    conversations.connect = { [weak self] model, session in
      let id = session.id
      model.write = { [weak self] bytes in
        await self?.pane(for: id)?.write(bytes)
      }
      model.processRunning = { [weak self] in
        guard let status = self?.pane(for: id)?.status else { return false }
        return status == .running || status == .starting
      }
      model.showTerminal = { [weak self] in
        self?.setPresentation(.terminal, of: id)
      }
      model.openInWebView = { [weak self] url, automatically in
        guard let self, let browser = self.browser,
          self.sessions.first(where: { $0.id == id })?.status != .archived
        else { return }
        if automatically {
          browser.open(url, in: id, openedBy: .agent)
        } else {
          browser.openLink(url, in: id)
        }
      }
      model.restart = { [weak self] in
        Task { await self?.restart(id) }
      }
      model.canRestart = { [weak self] in
        guard let self, let session = self.sessions.first(where: { $0.id == id }) else {
          return false
        }
        return self.canRestart(session)
      }
      model.activity = self?.activities[id]?.activity
      model.isAgentReady = ConversationWorkspace.isReady(self?.activities[id])
    }
  }
}
