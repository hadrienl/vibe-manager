import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

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
      conversations.requestComposerFocus(for: id)
    }
  }

  /// Gives the keyboard to the selected session in the form it is shown in (#105): the composer
  /// of its conversation, or its terminal. The one rule behind every gesture that hands the
  /// keyboard back to the session — Escape in the notes, the web view put away, an answer sent
  /// from the palette, ⌘P.
  ///
  /// False when nothing took the request: no terminal, or a composer that cannot be typed into —
  /// its agent stopped, or waiting for an answer in the terminal. The keyboard then stays where
  /// it is. A stopped terminal still takes it, as it always has: its last output can be read.
  @discardableResult
  public func focusSession() -> Bool {
    keepsKeyboardInSidebar = false
    keyboardHeldInSidebarFor = nil
    guard let session = selectedSession, canClaimKeyboard else { return false }
    if presentation(of: session) == .conversation {
      guard launcher?.isRunning(session.id) == true else { return false }
      return conversations.requestComposerFocus(for: session.id)
    }
    guard let pane = pane(for: session.id) else { return false }
    pane.requestFocus()
    return true
  }

  /// Nothing over the window holds the keyboard: Open Quickly, drawn inside it, or a sheet.
  public var canClaimKeyboard: Bool {
    !quickOpen.isPresented && !isPresentingSheet
  }

  /// Whether one of the window's sheets asks to be shown — the ones `RootView` presents — or the
  /// new session's draft, which holds the keyboard as a sheet would (#177).
  public var isPresentingSheet: Bool {
    permissions?.isPresentingStep == true || isPresentingNewSession || pendingRestart != nil
      || pendingSwitch != nil || diagnosticsExport != nil || hookConsentRequest != nil
  }

  /// Whether the composer on screen takes the keyboard when its session comes on screen (#105).
  /// Not while the user walks the sidebar with the arrow keys: the list would lose them at the
  /// first row. Nor while several sessions are selected: see `terminalClaimsKeyboardOnActivation`.
  public var composerClaimsKeyboardOnActivation: Bool {
    !keepsKeyboardInSidebar && !sidebarHoldsKeyboard && canClaimKeyboard && !hasMultipleSelection
  }

  /// Whether the terminal on screen takes the keyboard when its session comes on screen. It
  /// does, as it always has — except for a session a ⌘-click or a ⇧-click just added to a
  /// selection of several (#128). The keyboard stays in the sidebar then, where the selection is
  /// made and used; it is the keyboard leaving the sidebar that brings the selection back to
  /// the session on screen, so that ⇧⌘W never closes sessions nobody is looking at. Nor for the
  /// session that took the place of an archived one: see `sidebarHoldsKeyboard`.
  public var terminalClaimsKeyboardOnActivation: Bool {
    !hasMultipleSelection && !sidebarHoldsKeyboard && canClaimKeyboard
  }

  /// View › Show Conversation / Show Terminal (⌥⌘T), for the selected session.
  public func togglePresentation() {
    guard let session = selectedSession, conversations.canShowConversation(session) else { return }
    setPresentation(
      presentation(of: session) == .conversation ? .terminal : .conversation,
      of: session.id)
  }

  public var canTogglePresentation: Bool {
    !isPresentingNewSession && (selectedSession.map(conversations.canShowConversation) ?? false)
  }

  /// Hooks each conversation model up to its session's terminal.
  func connectConversations() {
    conversations.connect = { [weak self] model, session in
      let id = session.id
      model.write = { [weak self] bytes in
        await self?.pane(for: id)?.write(bytes)
      }
      model.readScreen = { [weak self] in
        await self?.launcher?.screen(of: id)
      }
      model.processRunning = { [weak self] in
        guard let status = self?.pane(for: id)?.status else { return false }
        return status == .running || status == .starting
      }
      model.endedOnError = { [weak self] in
        guard let pane = self?.pane(for: id) else { return false }
        return ConversationStopReport.endedOnError(
          pane.status, wasStoppedOnPurpose: pane.wasStoppedOnPurpose)
      }
      model.launchFailure = { [weak self] in
        ConversationStopReport.launchFailure(of: self?.pane(for: id))
      }
      // As the kernel says: the same whether the application was open when it started or not.
      model.processStartDate = { [weak self] in
        guard let terminal = self?.pane(for: id)?.session,
          case .running(let processIdentifier) = await terminal.state()
        else { return nil }
        return SystemProcessLivenessProbe().startTime(of: processIdentifier)
      }
      model.showTerminal = { [weak self] in
        self?.setPresentation(.terminal, of: id)
      }
      model.chooseFiles = { [weak self] in
        guard let self else { return }
        if self.selectedSessionID != id { self.select(id) }
        self.beginAttachingFiles()
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
      // The session's own requests, answered in its conversation as the palette answers those
      // of the others: the same arming rules, the same keystrokes.
      model.pendingRequest = { [weak self] in
        guard let self, let request = self.activity(for: id)?.requests.first else { return nil }
        return ConversationRequest(
          request: request,
          answers: (self.requestAnswering[request.id] ?? .inTerminalOnly(.notSupported)).answers,
          isSending: self.answeringRequestIDs.contains(request.id))
      }
      model.answerRequest = { [weak self] answer, requestID in
        await self?.answer(answer, to: requestID) ?? false
      }
      model.activity = self?.activity(for: id)?.activity
      model.isAgentReady = ConversationWorkspace.isReady(self?.activity(for: id))
    }
  }
}

/// What the foot of a conversation says of an agent that is no longer running (#235).
enum ConversationStopReport {
  /// Ended on an error nobody asked for: an exit status other than 0, a signal, a terminal that
  /// failed. Never a session closed or quit on purpose, whatever its process reported.
  static func endedOnError(_ status: TerminalPaneModel.Status, wasStoppedOnPurpose: Bool) -> Bool {
    guard !wasStoppedOnPurpose else { return false }
    switch status {
    case .exited(let code): return code != 0
    case .terminated, .failed: return true
    case .starting, .running: return false
    }
  }

  /// Why the agent could not be launched, as its terminal says it.
  @MainActor
  static func launchFailure(of pane: TerminalPaneModel?) -> ConversationLaunchFailure? {
    pane?.failure.map { ConversationLaunchFailure(message: $0.message, suggestion: $0.suggestion) }
  }
}
