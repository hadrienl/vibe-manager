import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The session's notes, from the toolbar (#578): a sheet with lines when there are notes, an empty
/// one otherwise. It opens the editor under it, or shows and hides the floating panel.
struct NotesToolbarButton: View {
  let model: AppModel

  var body: some View {
    let presentation = model.notesPresentation
    let hasNotes = model.selectedSessionHasNotes
    Button {
      model.toggleNotes()
    } label: {
      Label {
        Text("Session Notes", bundle: .module)
      } icon: {
        Image(systemName: hasNotes ? "doc.text" : "doc")
      }
    }
    .disabled(!model.canShowNotes && !presentation.isShown)
    .instantTooltip(Text("Session Notes", bundle: .module))
    .accessibilityValue(accessibilityValue(hasNotes: hasNotes, presentation: presentation))
    .popover(
      isPresented: Binding(
        get: { presentation.isPopoverShown && model.canShowNotes },
        set: { if !$0 { model.notesPopoverDismissed() } }),
      arrowEdge: .bottom
    ) {
      if let session = model.selectedSession {
        NotesPopoverContent(model: model, session: session)
      }
    }
  }

  /// Whether there are notes; in the panel's placement, first whether the panel is shown, the
  /// button being its switch.
  private func accessibilityValue(hasNotes: Bool, presentation: NotesPresentation) -> Text {
    let notes =
      hasNotes
      ? Text("Contains notes", bundle: .module, comment: "Said of the toolbar's Notes button.")
      : Text("Empty", bundle: .module, comment: "Said of a session's notes that hold nothing.")
    guard presentation.placement == .panel else { return notes }
    let shown =
      presentation.isPanelShown
      ? Text("Shown", bundle: .module, comment: "The notes' floating window is shown.")
      : Text("Hidden", bundle: .module, comment: "The notes' floating window is hidden.")
    return shown + Text(verbatim: ", ") + notes
  }
}

/// The editor under the toolbar's button: the notes as the column showed them, with their state,
/// and the way out to a floating window.
struct NotesPopoverContent: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    let document = model.notes.document(for: session.id)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Notes", bundle: .module, comment: "The heading of a session's notes.")
          .font(.headline)
        Text(session.name)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        NotesStateLabel(document: document)
        Button {
          model.detachNotes()
        } label: {
          Image(systemName: "pip.enter")
        }
        .buttonStyle(.borderless)
        .instantTooltip(Self.detach)
        .accessibilityLabel(Self.detach)
        .accessibilityIdentifier("notes-detach")
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 2)
      SessionNotesSection(
        session: session, document: document, notes: model.notes,
        ticketTitles: model.ticketTitles, leave: { model.leaveNotes() })
    }
    .frame(width: 380, height: 440)
  }

  static var detach: Text {
    Text("Detach to a Floating Window", bundle: .module)
  }
}

/// The floating panel's content: the same editor, following the session on screen. Its name is
/// in the window's title.
struct NotesPanelContent: View {
  let model: AppModel

  var body: some View {
    Group {
      if model.canShowNotes, let session = model.selectedSession {
        let document = model.notes.document(for: session.id)
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Spacer(minLength: 0)
            NotesStateLabel(document: document)
              .id(session.id)
          }
          .padding(.horizontal, 12)
          .padding(.top, 6)
          SessionNotesSection(
            session: session, document: document, notes: model.notes,
            ticketTitles: model.ticketTitles, leave: { model.leaveNotes() })
        }
      } else {
        ContentUnavailableView {
          Label {
            Text("No session selected", bundle: .module)
          } icon: {
            Image(systemName: "doc")
          }
        } description: {
          Text("Select a session to see its notes.", bundle: .module)
        }
      }
    }
    .frame(minWidth: 260, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
  }
}

/// In the panel's title bar: back to the popover under the toolbar's button.
struct NotesReattachButton: View {
  let model: AppModel

  var body: some View {
    Button {
      model.attachNotes()
    } label: {
      Image(systemName: "pip.exit")
    }
    .buttonStyle(.borderless)
    .instantTooltip(Self.reattach)
    .accessibilityLabel(Self.reattach)
    .accessibilityIdentifier("notes-reattach")
    .padding(.horizontal, 8)
  }

  static var reattach: Text {
    Text("Reattach to the Toolbar", bundle: .module)
  }
}
