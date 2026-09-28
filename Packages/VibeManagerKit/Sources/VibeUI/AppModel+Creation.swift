import AppKit
import Foundation
import VibeApplication
import VibeDomain

/// A session the user asked for and does not have yet: what the window shows between Create and
/// the terminal. Saving it and starting its agent take seconds, and the sheet no longer waits for
/// them — the window has to say, at once, where the user is going.
public struct SessionInCreation: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Checked and written to the store.
    case saving
    /// Stored, and its agent starting.
    case starting
  }

  public let name: String
  public let appearance: SessionAppearance
  /// The project icon the draft wears, not yet copied into the data folder.
  public let iconData: Data?
  public internal(set) var phase: Phase = .saving
  /// Known once the session is stored.
  public internal(set) var sessionID: SessionID?
  /// Whether the window is still on it. Another session selected meanwhile is where the user
  /// chose to be: the new one is not brought on screen over it once it is ready.
  public internal(set) var isFollowed = true

  init(draft: SessionDraft) {
    name = draft.trimmedName
    appearance = draft.effectiveAppearance
    iconData = draft.usesProjectIcon ? draft.projectIcon?.pngData : nil
  }

  public var icon: NSImage? { iconData.flatMap(NSImage.init(data:)) }
}

extension AppModel {
  /// The placeholder the detail column shows instead of the session on screen, if any.
  public var shownCreation: SessionInCreation? {
    guard let creation = sessionInCreation, creation.isFollowed else { return nil }
    guard let id = creation.sessionID else { return creation }
    return selectedSessionID == id ? creation : nil
  }

  /// The row the sidebar draws for it, until the session has a row of its own there.
  public var creationRow: SessionInCreation? {
    guard let creation = sessionInCreation else { return nil }
    if let id = creation.sessionID, displayedSessions.contains(where: { $0.id == id }) {
      return nil
    }
    return creation
  }

  /// Create, optimistically: the draft gives way now, and the window shows the session to come
  /// while it is checked, stored and started. A draft that is refused on the way comes back, with
  /// its problems, exactly as it was left.
  ///
  /// Only a draft that passes its own checks gets here: those cost nothing, and a draft that went
  /// and came straight back for a missing folder would only flicker.
  ///
  /// One session is made this way at a time. A second Send pressed while the first is still on
  /// its way waits in its draft, as every creation used to.
  public func submitNewSession(launching: Bool) {
    guard let sheet = newSessionModel, !sheet.isSubmitting else { return }
    // Named now, so that the session to come shows the name it will have.
    sheet.settleName()
    guard sessionInCreation == nil else {
      Task {
        guard let creation = await sheet.submit() else { return }
        if newSessionModel === sheet {
          isPresentingNewSession = false
          newSessionModel = nil
        }
        await publish(creation, launching: launching, tracked: false)
      }
      return
    }
    sessionInCreation = SessionInCreation(draft: sheet.draft)
    isPresentingNewSession = false
    newSessionModel = nil
    Task {
      guard let creation = await sheet.submit() else {
        sessionInCreation = nil
        // Back to the draft, unless another one was begun meanwhile: that one is the user's now.
        if newSessionModel == nil {
          newSessionModel = sheet
          showNewSessionDraft()
        }
        return
      }
      await publish(creation, launching: launching, tracked: true)
    }
  }

  /// Brings the draft on screen, the keyboard in its composer.
  public func showNewSessionDraft() {
    guard newSessionModel != nil else { return }
    isPresentingNewSession = true
    newSessionFocusRequest += 1
  }

  /// The user goes elsewhere: the draft stays for later, unless nothing of theirs is in it yet —
  /// then it goes, as an empty draft left in the sidebar would only be in the way.
  public func leaveNewSessionDraft() {
    guard isPresentingNewSession else { return }
    isPresentingNewSession = false
    if let draft = newSessionModel, draft.isPristine, !draft.isSubmitting {
      newSessionModel = nil
    }
  }

  /// Escape in the draft: an empty draft is discarded, one with something in it is put aside, and
  /// the session underneath comes back.
  public func dismissNewSessionDraft() {
    leaveNewSessionDraft()
    focusSession()
  }

  func creationWasLeft(for id: SessionID?) {
    guard let creation = sessionInCreation, creation.isFollowed else { return }
    // Selecting nothing is the list losing its selection, not the user going elsewhere.
    guard let id, id != creation.sessionID else { return }
    sessionInCreation?.isFollowed = false
  }
}
