import AppKit
import Foundation
import VibeApplication
import VibeDomain

/// Renaming a session and changing its badge after its creation (#183).
///
/// Only what the session is shown as changes: the terminal, the agent and its conversation, the
/// branch and the worktree never hear of it. Everything that shows the session reads `sessions`,
/// and follows as soon as the change is shown.
extension AppModel {
  var identityEdits: EditSessionIdentity {
    EditSessionIdentity(
      repository: repository, icons: iconStore, projectIcons: projectIcons,
      diagnostics: diagnostics)
  }

  /// Whether a session can be renamed or given another badge now: one, stored, and not under a
  /// new session's draft.
  public func canEditIdentity(of id: SessionID?) -> Bool {
    guard let id, !isPresentingNewSession else { return false }
    return sessions.contains { $0.id == id }
  }

  /// Where a rename or a badge asked for from the menu bar is edited: on the session's row when
  /// the sidebar shows it, in the inspector's header otherwise — a folded group is not unfolded
  /// for it.
  func editingPlace(for id: SessionID) -> SessionIdentityEditing.Place {
    guard layout.columns.isSidebarVisible,
      displayedSessions.contains(where: { $0.id == id })
    else { return .inspector }
    return .sidebar
  }

  /// The inspector's header shows the session on screen: it is brought there, and shown.
  private func prepare(_ place: SessionIdentityEditing.Place, for id: SessionID) {
    guard place == .inspector else { return }
    if selectedSessionID != id { select(id) }
    if !layout.columns.isInspectorVisible { layout.setInspectorVisible(true) }
  }

  // MARK: - Rename

  /// Turns the session's name into a field, where `place` says or where it is seen.
  public func beginRename(_ id: SessionID, in place: SessionIdentityEditing.Place? = nil) {
    guard canEditIdentity(of: id) else { return }
    endAppearanceEditing()
    endThemeEditing()
    let place = place ?? editingPlace(for: id)
    prepare(place, for: id)
    renaming = SessionIdentityEditing(sessionID: id, place: place)
  }

  /// Escape: the field closes on the name the session had.
  public func cancelRename() {
    renaming = nil
  }

  /// Gives the session the name typed. Returns why it is refused, the field staying open and the
  /// session keeping its name; `nil` once it is written — or when it was the same name.
  @discardableResult
  public func commitRename(_ id: SessionID, to raw: String) async -> SessionDraftIssue? {
    let name: String
    switch SessionName.validated(raw) {
    case .failure(let issue): return issue
    case .success(let valid): name = valid
    }
    if renaming?.sessionID == id { renaming = nil }
    guard let session = sessions.first(where: { $0.id == id }), session.name != name else {
      return nil
    }
    var identity = SessionIdentity(of: session)
    identity.name = name
    showIdentity(identity, of: id)
    do {
      if let change = try await identityEdits.rename(id, to: name) {
        sidebarHistory.record(change)
        Announcer.announce(
          LocalizedStringResource(
            "Session renamed: \(name)", bundle: .module,
            comment: "Said by VoiceOver once a session is renamed. Its new name."))
      }
    } catch let issue as SessionDraftIssue {
      await reload()
      return issue
    } catch {
      identityFailure = Self.describe(error)
    }
    await identityDidChange(of: id)
    return nil
  }

  // MARK: - Badge

  /// Opens the badge's popover on the session's row, or on the inspector's header.
  public func beginAppearanceEditing(
    _ id: SessionID, in place: SessionIdentityEditing.Place? = nil
  ) {
    guard canEditIdentity(of: id), let session = sessions.first(where: { $0.id == id }) else {
      return
    }
    endAppearanceEditing()
    endThemeEditing()
    renaming = nil
    let place = place ?? editingPlace(for: id)
    prepare(place, for: id)
    let editor = SessionAppearanceEditor(
      editing: SessionIdentityEditing(sessionID: id, place: place), original: session.appearance)
    appearanceEditor = editor
    let edits = identityEdits
    let palette = appearancePalette.offered
    Task { [weak self] in
      let (appearance, icon) = await edits.defaultAppearance(for: session, palette: palette)
      if let icon { self?.icons.insert(icon) }
      editor.found(default: appearance, icon: icon)
    }
  }

  /// The badge a session is drawn with: the one previewed while its popover is open.
  public func displayedAppearance(of session: WorkSession) -> SessionAppearance {
    if let appearanceEditor, appearanceEditor.sessionID == session.id {
      return appearanceEditor.current
    }
    return session.appearance
  }

  /// Escape: the preview goes, and nothing is written.
  public func cancelAppearanceEditing() {
    appearanceEditor = nil
  }

  /// The popover closed any other way: the badge chosen is kept, as one change for ⌘Z.
  public func endAppearanceEditing() {
    guard let editor = appearanceEditor else { return }
    appearanceEditor = nil
    guard editor.hasChanges,
      let session = sessions.first(where: { $0.id == editor.sessionID })
    else { return }
    let id = editor.sessionID
    let appearance = editor.current
    let icon = editor.iconToKeep
    var identity = SessionIdentity(of: session)
    identity.appearance = appearance
    showIdentity(identity, of: id)
    Task { [weak self] in
      guard let self else { return }
      do {
        if let change = try await self.identityEdits.setAppearance(
          appearance, keeping: icon, for: id)
        {
          self.sidebarHistory.record(change)
        }
      } catch {
        self.identityFailure = Self.describe(error)
      }
      await self.identityDidChange(of: id, renamed: false)
    }
  }

  // MARK: - Conversation theme (#274)

  /// Opens the Change Theme popover on the session's row, or on the inspector's header.
  public func beginThemeEditing(_ id: SessionID, in place: SessionIdentityEditing.Place? = nil) {
    guard canEditIdentity(of: id), let session = sessions.first(where: { $0.id == id }) else {
      return
    }
    endAppearanceEditing()
    endThemeEditing()
    renaming = nil
    let place = place ?? editingPlace(for: id)
    prepare(place, for: id)
    themeEditing = SessionThemeEditing(
      editing: SessionIdentityEditing(sessionID: id, place: place),
      original: session.conversationTheme)
  }

  /// A card chosen in the popover: the conversation shows it at once, nothing is written yet.
  public func previewTheme(_ theme: String?) {
    themeEditing?.current = theme
  }

  /// The theme a session's conversation is drawn with: the one previewed while its popover is
  /// open, `nil` following the settings.
  public func displayedConversationTheme(of session: WorkSession) -> String? {
    if let themeEditing, themeEditing.editing.sessionID == session.id {
      return themeEditing.current
    }
    return session.conversationTheme
  }

  /// Escape: the preview goes, and nothing is written.
  public func cancelThemeEditing() {
    themeEditing = nil
  }

  /// The popover closed any other way: the theme chosen is kept, as one change for ⌘Z.
  public func endThemeEditing() {
    guard let editing = themeEditing else { return }
    themeEditing = nil
    let id = editing.editing.sessionID
    guard editing.hasChanges, let session = sessions.first(where: { $0.id == id }) else { return }
    let theme = editing.current
    var identity = SessionIdentity(of: session)
    identity.conversationTheme = theme
    showIdentity(identity, of: id)
    Task { [weak self] in
      guard let self else { return }
      do {
        if let change = try await self.identityEdits.setConversationTheme(theme, for: id) {
          self.sidebarHistory.record(change)
        }
      } catch {
        self.identityFailure = Self.describe(error)
      }
      await self.identityDidChange(of: id, renamed: false)
    }
  }

  // MARK: - Undo

  public var canUndoSidebarChange: Bool { sidebarHistory.canUndo }
  public var canRedoSidebarChange: Bool { sidebarHistory.canRedo }

  /// What ⌘Z (or ⇧⌘Z, with `redo`) does where the sidebar or the inspector holds the keyboard:
  /// the last rename, change of icon (#183), archive (#242) or status changed from the keyboard
  /// (#240). `nil` with nothing to undo, or with the keyboard elsewhere (`keyboardHere` false):
  /// ⌘Z then goes on to the window, whose own undo — the draft of a new session given back, for
  /// one — is never hidden by this one.
  ///
  /// A text being edited there — the name field, the notes — undoes its own typing: the command
  /// is taken above it, by the view that declares it, before the window would have handed it
  /// down to the text's undo manager.
  public func sidebarUndoAction(redo: Bool, keyboardHere: Bool = true) -> (() -> Void)? {
    guard keyboardHere, redo ? canRedoSidebarChange : canUndoSidebarChange else { return nil }
    return { [weak self] in
      let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
      if Self.isEditingText(responder) {
        let manager = responder?.undoManager
        if redo { manager?.redo() } else { manager?.undo() }
        return
      }
      Task { [weak self] in
        if redo {
          await self?.redoSidebarChange()
        } else {
          await self?.undoSidebarChange()
        }
      }
    }
  }

  /// Whether the keyboard is in a text being edited: a field's editor, the notes.
  static func isEditingText(_ responder: NSResponder?) -> Bool {
    responder is NSText
  }

  /// ⌘Z in the sidebar or the inspector: the last rename, badge change, archive or status change,
  /// unless the session has changed since — then nothing is undone, and the Mac beeps.
  public func undoSidebarChange() async {
    sidebarHistory.keep(only: Set(sessions.map(\.id)))
    switch sidebarHistory.popUndo() {
    case nil:
      beep()
    case .identity(let change):
      if let applied = await apply(change) {
        sidebarHistory.didUndo(applied)
      }
    case .archive(let archives):
      await undoArchive(archives)
    case .status(let status):
      await undoStatusChange(status)
    }
  }

  /// ⇧⌘Z: the rename or badge change undone last, again.
  public func redoSidebarChange() async {
    sidebarHistory.keep(only: Set(sessions.map(\.id)))
    guard let change = sidebarHistory.popRedo() else { return beep() }
    if let applied = await apply(change) {
      sidebarHistory.didRedo(applied)
    }
  }

  private func apply(_ change: SessionIdentityChange) async -> SessionIdentityChange? {
    renaming = nil
    appearanceEditor = nil
    themeEditing = nil
    showIdentity(change.after, of: change.id)
    var applied: SessionIdentityChange?
    do {
      applied = try await identityEdits.apply(change)
    } catch {
      applied = nil
    }
    if applied == nil { beep() }
    await identityDidChange(of: change.id, renamed: change.before.name != change.after.name)
    return applied
  }

  public func dismissIdentityFailure() {
    identityFailure = nil
  }

  // MARK: - Following

  /// What the store now holds is shown, and the notifications already posted for the session take
  /// its new name, without a sound.
  private func identityDidChange(of id: SessionID, renamed: Bool = true) async {
    await reload()
    // Only a new name changes what they say; and only while requests are notified at all.
    guard renamed, notifiesRequests, !(floatingPanel?.isEnabled ?? false),
      let notifier = requestNotifier
    else { return }
    for pending in allPendingRequests
    where pending.session.id == id && postedRequestIDs.contains(pending.id) {
      var notification = notification(for: pending)
      notification.isSilent = true
      notifier.post(notification)
    }
  }

  private static func describe(_ error: any Error) -> String {
    switch error as? SessionIdentityError {
    case .iconNotKept:
      return String(
        localized: "The project's icon could not be copied into the data folder.",
        bundle: .module)
    case .invalidAppearance:
      return String(localized: "This icon cannot be stored.", bundle: .module)
    case .invalidConversationTheme:
      return String(localized: "This theme cannot be stored.", bundle: .module)
    case .sessionNotFound:
      return String(localized: "This session no longer exists.", bundle: .module)
    case nil:
      return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }
}
