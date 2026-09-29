import Foundation
import VibeApplication
import VibeDomain

/// Several sessions selected in the sidebar (#77).
///
/// `selectedSessionID` keeps its meaning: the session on screen, in the main area and the
/// inspector. The selection only says what the next command applies to.
extension AppModel {
  /// What the sidebar's list draws as selected.
  /// Empty over a new session's draft (#177): the draft's row is the one on screen.
  public var selectedSessionIDs: Set<SessionID> {
    guard !isPresentingNewSession else { return [] }
    guard selection.isMultiple else { return Set(selectedSessionID.map { [$0] } ?? []) }
    return selection.ids
  }

  public var hasMultipleSelection: Bool { selection.isMultiple }

  /// Whether a session is what the main area shows: one is selected, and no new session's draft
  /// covers it (#177).
  public var isSessionOnScreen: Bool {
    selectedSessionID != nil && !isPresentingNewSession
  }

  /// The sessions a command of the Session menu applies to, in the order the sidebar draws them:
  /// the selection, or the session on screen.
  public var commandTargets: [SessionID] {
    guard selection.isMultiple else { return selectedSessionID.map { [$0] } ?? [] }
    let ids = selection.ids
    let drawn = displayedSessions.map(\.id).filter { ids.contains($0) }
    let missing = selection.members.filter { !drawn.contains($0) }
    return drawn + missing
  }

  /// What the list asks for after a click, a ⇧-click, a ⌘-click or ⌘A — or an arrow key,
  /// `byKeyboard`: the session reached then leaves the keyboard in the list (#105).
  public func selectFromList(_ ids: Set<SessionID>, byKeyboard: Bool = false) {
    // The list shows no selection over a new session's draft (#177): whatever the user picks in
    // it — the session underneath included — is where they go. Nothing picked is the list
    // clearing itself, not the user leaving.
    guard !ids.isEmpty || !isPresentingNewSession else { return }
    leaveNewSessionDraft()
    defer { if byKeyboard { keepsKeyboardInSidebar = true } }
    var ids = ids
    // The outline view drops the selection of a row it folds away: folding the group of the
    // session on screen must keep it, as `selectFromList(_: SessionID?)` does.
    if let selectedSessionID, !ids.contains(selectedSessionID),
      !displayedSessions.contains(where: { $0.id == selectedSessionID }),
      orderedSessions.contains(where: { $0.id == selectedSessionID })
    {
      ids.insert(selectedSessionID)
    }
    guard ids.count > 1 else {
      guard let only = ids.first else {
        selectFromList(nil as SessionID?)
        return
      }
      // A plain click: exactly what it was before there could be several.
      if selection.isMultiple || only != selectedSessionID { select(only) }
      return
    }
    var next = selection
    next.applyList(ids, displayOrder: displayedSessions.map(\.id))
    guard next != selection else { return }
    let count = next.members.count
    let countChanged = count != selection.members.count
    selection = next
    if next.displayed != selectedSessionID {
      showFromSelection(next.displayed)
    }
    if countChanged {
      Announcer.announce(
        String(
          localized: "\(count) sessions selected", bundle: .module,
          comment: "Said by VoiceOver when the sidebar's selection grows or shrinks."))
    }
  }

  /// Back to the session on screen alone: Escape, or the keyboard leaving the sidebar.
  public func collapseSelection() {
    guard selection.isMultiple else { return }
    selection.collapse(to: selectedSessionID)
  }

  /// A selection never holds a row the sidebar does not draw.
  func pruneSelection() {
    guard selection.isMultiple else { return }
    selection.prune(keeping: Set(displayedSessions.map(\.id)))
  }
}
