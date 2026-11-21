import Foundation
import Observation
import VibeApplication

/// Where the session's notes are on screen (#578): under the toolbar's button, in a panel that
/// stays open, or nowhere.
///
/// The placement — popover or panel — is the user's and is kept in the layout; whether either is
/// open is not, and a relaunch opens neither.
@MainActor
@Observable
public final class NotesPresentation {
  /// The popover under the toolbar's button.
  public private(set) var isPopoverShown = false
  /// The floating panel.
  public private(set) var isPanelShown = false {
    didSet {
      if isPanelShown != oldValue { panelVisibilityChanged?() }
    }
  }
  /// AppKit must dismiss the previous window before SwiftUI opens the next presentation.
  @ObservationIgnored var panelVisibilityChanged: (() -> Void)?
  /// Whether the panel holds the keyboard, as its window says: a second Edit Notes hands it back.
  @ObservationIgnored var isPanelKey = false
  /// Gives the keyboard back to the workspace window, for the panel's editor to let go of it. Set
  /// by the panel's controller, which knows the windows.
  @ObservationIgnored var returnFromPanel: (() -> Void)?

  private let layout: WorkspaceLayoutController

  init(layout: WorkspaceLayoutController) {
    self.layout = layout
  }

  public var placement: NotesPlacement { layout.notesPlacement }

  /// Whether the notes are on screen, in whichever placement.
  public var isShown: Bool {
    switch placement {
    case .popover: isPopoverShown
    case .panel: isPanelShown
    }
  }

  /// The toolbar's button: opens or closes the notes where the user keeps them.
  func toggle() {
    switch placement {
    case .popover: isPopoverShown.toggle()
    case .panel: isPanelShown.toggle()
    }
  }

  /// Shows the notes in their placement, closing the other one.
  func show() {
    switch placement {
    case .popover:
      isPanelShown = false
      isPopoverShown = true
    case .panel:
      isPopoverShown = false
      isPanelShown = true
    }
  }

  /// Detach to a Floating Window: the panel, from now on.
  func detach() {
    layout.setNotesPlacement(.panel)
    show()
  }

  /// Reattach: the popover again, from now on.
  func attach() {
    layout.setNotesPlacement(.popover)
    show()
  }

  /// Closed by a click elsewhere, Escape, or another session.
  func popoverClosed() {
    isPopoverShown = false
  }

  /// Closed by its own button or ⌘W.
  func panelClosed() {
    isPanelShown = false
    isPanelKey = false
  }
}

extension AppModel {
  /// The toolbar's Notes button (#578). Without a session there are no notes to show.
  public var canShowNotes: Bool {
    selectedSession != nil && !isPresentingNewSession
  }

  /// Whether the session on screen has notes: what the button's icon says, a sheet with lines or
  /// an empty one.
  public var selectedSessionHasNotes: Bool {
    guard let id = selectedSessionID else { return false }
    return notes.hasNotes(for: id)
  }

  public func toggleNotes() {
    guard canShowNotes || notesPresentation.isShown else { return }
    let wasShown = notesPresentation.isShown
    notesPresentation.toggle()
    if wasShown { notesClosed() }
  }

  /// Edit Notes: the editor opens where the user keeps it and takes the keyboard. Asked again while
  /// it holds the keyboard, the keyboard goes back to the session.
  public func focusNotes() {
    guard canShowNotes else { return }
    let presentation = notesPresentation
    switch presentation.placement {
    case .popover where presentation.isPopoverShown:
      leaveNotes()
      return
    case .panel where presentation.isPanelShown && presentation.isPanelKey:
      leaveNotes()
      return
    default:
      break
    }
    presentation.show()
    notes.requestFocus()
  }

  /// Escape in the editor, or a second Edit Notes: the popover closes, the panel stays, and the
  /// session takes the keyboard back.
  public func leaveNotes() {
    if notesPresentation.isPopoverShown {
      notesPresentation.popoverClosed()
      notesClosed()
    }
    if notesPresentation.isPanelKey {
      notesPresentation.returnFromPanel?()
    }
    focusSession()
  }

  public func detachNotes() {
    notesPresentation.detach()
    notes.requestFocus()
  }

  public func attachNotes() {
    notesPresentation.attach()
    notes.requestFocus()
  }

  /// The popover dismissed by AppKit: a click elsewhere, or Escape outside the editor.
  public func notesPopoverDismissed() {
    guard notesPresentation.isPopoverShown else { return }
    notesPresentation.popoverClosed()
    notesClosed()
  }

  /// The panel closed by its own button or ⌘W.
  public func notesPanelClosed() {
    guard notesPresentation.isPanelShown else { return }
    notesPresentation.panelClosed()
    notesClosed()
  }

  /// Another session on screen: the popover closes over the notes it was showing; the panel
  /// follows the selection.
  func notesSelectionChanged() {
    notesPresentation.popoverClosed()
  }

  /// Every keystroke is written already; what waits for its pause is written now, so that nothing
  /// stays Edited once the notes are out of sight.
  private func notesClosed() {
    guard let id = selectedSessionID else { return }
    Task { [notes] in await notes.flush(id) }
  }
}
