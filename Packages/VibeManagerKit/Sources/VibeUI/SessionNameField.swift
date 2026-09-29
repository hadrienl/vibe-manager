import AppKit
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
  var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  @State private var name = ""
  @State private var issue: SessionDraftIssue?
  @State private var isCommitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      NameTextField(
        text: $name,
        font: font,
        placeholder: String(
          localized: "Session name", bundle: .module,
          comment: "The field that renames a session."),
        submit: { commit(leaving: false) },
        cancel: { model.cancelRename() },
        leave: { commit(leaving: true) }
      )
      // As tall as the name it replaces: a bordered field would make the row grow. Its frame is
      // drawn around it, outside the layout.
      .background {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color(nsColor: .textBackgroundColor))
          .overlay {
            RoundedRectangle(cornerRadius: 4)
              .strokeBorder(
                issue == nil ? Color(nsColor: .keyboardFocusIndicatorColor) : Color.red,
                lineWidth: issue == nil ? 1 : 1.5)
          }
          .padding(.horizontal, -4)
          .padding(.vertical, -1)
          .allowsHitTesting(false)
      }
      .onAppear { name = session.name }
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

/// The field itself, in AppKit: it takes the keyboard as soon as it is in the window, the name
/// selected, as the Finder does.
///
/// SwiftUI's focus, asked for as the field appears, does not hold in a row of the sidebar: the
/// list takes the keyboard back as the double-click ends, and a field that never had it cannot be
/// left — a click elsewhere did nothing until the user had clicked in it first.
private struct NameTextField: NSViewRepresentable {
  @Binding var text: String
  let font: NSFont
  let placeholder: String
  let submit: () -> Void
  let cancel: () -> Void
  let leave: () -> Void

  func makeNSView(context: Context) -> FocusingTextField {
    let field = FocusingTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.textColor = .textColor
    field.placeholderString = placeholder
    field.setAccessibilityLabel(placeholder)
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: FocusingTextField, context: Context) {
    context.coordinator.parent = self
    field.font = font
    if field.currentEditor() == nil, field.stringValue != text {
      field.stringValue = text
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: NameTextField
    /// Escape has already said how the editing ends.
    private var cancelled = false

    init(parent: NameTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.text = control.stringValue
        parent.submit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        cancelled = true
        parent.cancel()
        return true
      default:
        return false
      }
    }

    /// The keyboard went elsewhere: a click on another row, in the terminal, another window.
    func controlTextDidEndEditing(_ notification: Notification) {
      guard !cancelled else { return }
      if let field = notification.object as? NSTextField { parent.text = field.stringValue }
      parent.leave()
    }
  }
}

/// Takes the keyboard once it is in a window, after the event that inserted it is over.
final class FocusingTextField: NSTextField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self)
      self.currentEditor()?.selectAll(nil)
    }
  }
}
