import AppKit
import Foundation
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

/// Where a drop on a session goes (#42).
public enum SessionDropRoute: Equatable, Sendable {
  /// Files become chips of the composer, text joins the draft: nothing is sent.
  case conversation
  /// Typed at the cursor of the terminal, without Return. `fallback` when the session is shown as
  /// a conversation that cannot be written to from here, and the view says so.
  case terminal(fallback: Bool)
  case refused(SessionDropRefusal)

  public var isRefused: Bool {
    if case .refused = self { return true }
    return false
  }

  /// Pure, so that every state of a session can be tested against it.
  ///
  /// Joining a file sends nothing, so a composer waiting for the agent to start or for an answer
  /// in the terminal still takes it: the file waits in the composer until it can be sent. A
  /// conversation not yet read — dropped on from the sidebar — follows its process.
  public static func decide(
    isArchived: Bool,
    presentation: SessionPresentation,
    isProcessRunning: Bool,
    composer: ConversationModel.ComposerState?
  ) -> SessionDropRoute {
    if isArchived { return .refused(.archived) }
    switch presentation {
    case .terminal:
      return isProcessRunning ? .terminal(fallback: false) : .refused(.stopped)
    case .conversation:
      switch composer {
      case .none: return isProcessRunning ? .conversation : .refused(.stopped)
      case .ready, .answeringQuestion, .awaitingAnswer, .starting: return .conversation
      case .stopped: return .refused(.stopped)
      case .unavailable: return isProcessRunning ? .terminal(fallback: true) : .refused(.stopped)
      }
    }
  }

  /// Where a drop on one of the session's side terminals goes (#139): typed into that terminal
  /// while its shell runs, whatever the session shows and whether its agent runs.
  public static func decideSideTerminal(isArchived: Bool, isShellRunning: Bool) -> SessionDropRoute
  {
    if isArchived { return .refused(.archived) }
    return isShellRunning ? .terminal(fallback: false) : .refused(.shellNotRunning)
  }
}

public enum SessionDropRefusal: Equatable, Sendable {
  case stopped
  case archived
  /// The shell of the side terminal dropped on has ended, or has not started yet.
  case shellNotRunning
}

/// Which of a session's terminals a drop is for.
public enum SessionDropTarget: Equatable, Sendable {
  /// The session itself: its agent's terminal or its conversation, whichever is on screen.
  case session
  /// One of its side terminals (#43), the tab dropped on or the one in front of the drawer (#139).
  case sideTerminal(TerminalID)
}

/// What the last drop on a session has to say, under its terminal or its composer (#42).
public struct SessionDropNotice: Equatable, Identifiable, Sendable {
  public let id = UUID()
  public let sessionID: SessionID
  public let messages: [String]
  /// A file was dropped from a folder the agent cannot read without Full Disk Access.
  public let offersFullDiskAccess: Bool
}

extension AppModel {
  /// Where a drop on the session, or on one of its side terminals, would go now.
  public func dropRoute(for id: SessionID, target: SessionDropTarget = .session) -> SessionDropRoute
  {
    guard let session = sessions.first(where: { $0.id == id }) else {
      return .refused(.stopped)
    }
    if case .sideTerminal(let terminalID) = target {
      return SessionDropRoute.decideSideTerminal(
        isArchived: session.status == .archived,
        isShellRunning: sideTerminal(terminalID, of: id)?.pane.status == .running)
    }
    return SessionDropRoute.decide(
      isArchived: session.status == .archived,
      presentation: presentation(of: session),
      isProcessRunning: pane(for: id)?.status == .running,
      composer: conversations.existingModel(for: id)?.composerState)
  }

  /// A drop on the session, from its terminal, its conversation or its row of the sidebar, or on
  /// one of its side terminals.
  func deliverDrop(
    _ providers: [NSItemProvider], to id: SessionID, target: SessionDropTarget = .session
  ) async {
    guard !announceRefusal(for: id, target: target) else { return }
    let (items, unreadable) = await DropReader.read(providers)
    await deliver(items, unreadable: unreadable, to: id, target: target)
  }

  /// One of the session's side terminals, when its drawer has it.
  func sideTerminal(_ terminalID: TerminalID, of id: SessionID) -> DrawerTerminal? {
    terminals?.existingDrawer(for: id)?.terminals.first { $0.id == terminalID }
  }

  /// Session › Attach Files… (⌘O): the files chosen, for the selected session.
  /// Over a new session's draft, the files join its initial prompt (#177).
  public func beginAttachingFiles() {
    guard canAttachFiles else { return }
    isChoosingFilesToAttach = true
  }

  public var canAttachFiles: Bool {
    if isPresentingNewSession {
      return newSessionModel.map { $0.draft.templateFill == nil && !$0.isSubmitting } ?? false
    }
    return selectedSessionID.map { !dropRoute(for: $0).isRefused } ?? false
  }

  public func attachChosenFiles(_ files: [URL]) async {
    if isPresentingNewSession {
      newSessionModel?.attach(files)
      return
    }
    guard let id = selectedSessionID, !files.isEmpty else { return }
    guard !announceRefusal(for: id) else { return }
    await deliver(files.map { .file($0, isTemporary: false) }, unreadable: 0, to: id)
  }

  public func dismissDropNotice() {
    dropNotice = nil
  }

  // MARK: -

  /// Says why nothing can be dropped, when nothing can. Returns whether it refused.
  private func announceRefusal(for id: SessionID, target: SessionDropTarget = .session) -> Bool {
    guard case .refused(let refusal) = dropRoute(for: id, target: target) else { return false }
    Announcer.announce(
      Self.refusalAnnouncement(refusal, name: refusalName(for: id, target: target)))
    return true
  }

  /// What a refusal names: the session, or the side terminal whose shell does not run.
  private func refusalName(for id: SessionID, target: SessionDropTarget) -> String {
    if case .sideTerminal(let terminalID) = target, let terminal = sideTerminal(terminalID, of: id)
    {
      return terminal.title
    }
    return sessions.first(where: { $0.id == id })?.name ?? ""
  }

  static func refusalAnnouncement(_ refusal: SessionDropRefusal, name: String) -> String {
    switch refusal {
    case .stopped:
      String(
        localized: "Nothing dropped: \(name) is stopped.", bundle: .module,
        comment: "VoiceOver, after a drop refused. The argument is a session's name.")
    case .archived:
      String(
        localized: "Nothing dropped: \(name) is archived.", bundle: .module,
        comment: "VoiceOver, after a drop refused. The argument is a session's name.")
    case .shellNotRunning:
      String(
        localized: "Nothing dropped: the shell of \(name) is not running.", bundle: .module,
        comment: "VoiceOver, after a drop refused. The argument is a side terminal's title.")
    }
  }

  func deliver(
    _ items: [DroppedItem], unreadable: Int, to id: SessionID,
    target: SessionDropTarget = .session
  ) async {
    // What a promise was staged in goes whatever happens next, the session stopped meanwhile
    // included.
    defer {
      for case .staged(let url, _) in items {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
    }
    let route = dropRoute(for: id, target: target)
    guard !route.isRefused, let session = sessions.first(where: { $0.id == id }) else { return }
    var failed = unreadable
    var payloads: [DropPayload] = []
    for item in items {
      if let payload = await keep(item, for: id) {
        payloads.append(payload)
      } else {
        failed += 1
      }
    }
    // Written as paths or not at all: a name holding a control character could type on its own.
    let rejected = PathInsertion.words(for: payloads).rejected
    payloads.removeAll { rejected.contains($0) }

    var messages: [String] = []
    if failed > 0 {
      messages.append(
        String(
          localized: "Some of what was dropped could not be read and was left out.",
          bundle: .module))
    }
    for case .file(let url) in rejected {
      messages.append(
        String(
          localized:
            "“\(url.lastPathComponent)” can’t be sent: its name contains a control character.",
          bundle: .module, comment: "The argument is a file name."))
    }

    guard !payloads.isEmpty else {
      show(messages, offeringFullDiskAccess: false, for: id)
      return
    }
    switch route {
    case .conversation:
      let conversation = conversations.show(session)
      let files = payloads.compactMap { payload -> URL? in
        if case .file(let url) = payload { return url }
        return nil
      }
      let texts = payloads.filter { payload in
        guard case .text = payload else { return false }
        return true
      }
      let text = PathInsertion.words(for: texts).words.joined(separator: " ")
      if !text.isEmpty {
        let draft = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.draft = draft.isEmpty ? text : conversation.draft + " " + text
      }
      if !files.isEmpty {
        conversation.attach(files)
      } else {
        conversation.requestComposerFocus()
      }
      Announcer.announce(
        String(
          localized: "Attached to your message to \(session.name).", bundle: .module,
          comment: "VoiceOver, after a drop on a conversation. The argument is a session's name."))
    case .terminal(let fallback):
      let pane = dropPane(for: id, target: target)
      guard let pane, await pane.insert(payloads) else {
        // Stopped between the drop and now: said, rather than lost without a word.
        if pane?.status != .running {
          let refusal: SessionDropRefusal = target == .session ? .stopped : .shellNotRunning
          Announcer.announce(
            Self.refusalAnnouncement(refusal, name: refusalName(for: id, target: target)))
        }
        show(messages, offeringFullDiskAccess: false, for: id)
        return
      }
      if fallback {
        messages.append(
          String(
            localized:
              "This conversation can’t be written to from here: the drop was typed into the terminal.",
            bundle: .module))
      }
      if case .sideTerminal(let terminalID) = target {
        let title = sideTerminal(terminalID, of: id)?.title ?? ""
        Announcer.announce(
          String(
            localized: "Dropped into the side terminal \(title) of \(session.name).",
            bundle: .module,
            comment:
              "VoiceOver, after a drop on a side terminal. The arguments are its title, then its session's name."
          ))
      } else {
        Announcer.announce(
          String(
            localized: "Dropped into the terminal of \(session.name).", bundle: .module,
            comment: "VoiceOver, after a drop on a terminal. The argument is a session's name."))
      }
    case .refused:
      return
    }
    NSApp?.activate()

    let guarded = protectedLocation(of: payloads)
    if let (location, file) = guarded {
      messages.append(
        String(
          localized:
            "The agent may have to ask for access to \(location.label) to read “\(file)”.",
          bundle: .module,
          comment: "After a drop. The arguments are a protected folder, then a file name."))
    }
    show(messages, offeringFullDiskAccess: guarded != nil, for: id)
  }

  /// The terminal a drop is typed into: the agent's, or the side terminal dropped on.
  private func dropPane(for id: SessionID, target: SessionDropTarget) -> TerminalPaneModel? {
    switch target {
    case .session: pane(for: id)
    case .sideTerminal(let terminalID): sideTerminal(terminalID, of: id)?.pane
    }
  }

  /// A file that exists is handed as it is; what has no file of its own — or one the system is
  /// about to delete — is written into the session's drop folder first.
  private func keep(_ item: DroppedItem, for id: SessionID) async -> DropPayload? {
    switch item {
    case .file(let url, isTemporary: false):
      return .file(url)
    case .file(let url, isTemporary: true):
      guard let dropStore else { return nil }
      return (try? await dropStore.copy(url, suggestedName: url.lastPathComponent, for: id))
        .map(DropPayload.file)
    case .data(let data, let name):
      guard let dropStore else { return nil }
      return (try? await dropStore.save(data, suggestedName: name, for: id)).map(DropPayload.file)
    case .staged(let url, let name):
      guard let dropStore else { return nil }
      return (try? await dropStore.copy(url, suggestedName: name, for: id)).map(DropPayload.file)
    case .text(let text):
      return .text(text)
    }
  }

  /// The first dropped file an agent without Full Disk Access may be refused, and where it is.
  /// Silent while the access is not known: nothing is ever warned about on a guess.
  private func protectedLocation(
    of payloads: [DropPayload]
  ) -> (ProtectedFileLocation, String)? {
    guard permissions?.agentAccess == .notGranted else { return nil }
    for case .file(let url) in payloads {
      if let location = ProtectedFileLocation.covering(path: url.path) {
        return (location, url.lastPathComponent)
      }
    }
    return nil
  }

  private func show(_ messages: [String], offeringFullDiskAccess: Bool, for id: SessionID) {
    guard !messages.isEmpty else {
      if dropNotice?.sessionID == id { dropNotice = nil }
      return
    }
    let notice = SessionDropNotice(
      sessionID: id, messages: messages, offersFullDiskAccess: offeringFullDiskAccess)
    dropNotice = notice
    for message in messages { Announcer.announce(message) }
    // Read and gone: only a notice that offers something to do stays until dismissed.
    guard !offeringFullDiskAccess else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      if self?.dropNotice?.id == notice.id { self?.dropNotice = nil }
    }
  }
}
