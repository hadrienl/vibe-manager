import SwiftUI
import VibeApplication
import VibeDomain

/// A session's name, turned into a field to rename it in place (#183): on its row in the sidebar,
/// and in the inspector's header.
///
/// Return keeps the name, Escape keeps the old one, and so does leaving the field — it keeps the
/// new one when it can be kept. A name that cannot be is refused where it was typed, with the
/// reason under it, and the field stays open.
struct SessionNameField: View {
  let model: AppModel
  let session: WorkSession
  var font: Font = .body
  @State private var name = ""
  @State private var issue: SessionDraftIssue?
  @State private var isCommitting = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      TextField(text: $name) {
        Text("Session name", bundle: .module, comment: "The field that renames a session.")
      }
      .textFieldStyle(.roundedBorder)
      .font(font)
      .overlay {
        if issue != nil {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.red, lineWidth: 1.5)
            .allowsHitTesting(false)
        }
      }
      .focused($isFocused)
      .onAppear { name = session.name }
      // Once the field exists: asked for in the update that inserts it, the focus is dropped.
      .task { isFocused = true }
      .onSubmit { commit(leaving: false) }
      .onExitCommand { model.cancelRename() }
      .onChange(of: isFocused) { _, isFocused in
        if !isFocused { commit(leaving: true) }
      }
      .onChange(of: name) { issue = nil }
      .accessibilityIdentifier("session-name-field")
      .accessibilityHint(issue.map { Text(verbatim: $0.message) } ?? Text(verbatim: ""))
      if let issue {
        IssueLabel(issue: issue)
          .accessibilityHidden(true)
      }
    }
  }

  /// A name refused as the field is left is dropped: the session keeps the one it had, rather
  /// than holding the keyboard the user has just taken elsewhere.
  private func commit(leaving: Bool) {
    guard !isCommitting, model.renaming?.sessionID == session.id else { return }
    if case .failure(let refusal) = SessionName.validated(name) {
      announce(refusal)
      if leaving {
        model.cancelRename()
      } else {
        issue = refusal
      }
      return
    }
    isCommitting = true
    let typed = name
    Task {
      let refusal = await model.commitRename(session.id, to: typed)
      isCommitting = false
      if let refusal {
        issue = refusal
        announce(refusal)
      }
    }
  }

  private func announce(_ refusal: SessionDraftIssue) {
    Announcer.announce(
      LocalizedStringResource(
        "Name refused: \(refusal.message)", bundle: .module,
        comment: "Said by VoiceOver when a session's new name is refused. The reason."))
  }
}
