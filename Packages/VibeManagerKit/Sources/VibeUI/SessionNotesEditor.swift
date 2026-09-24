import AppKit
import SwiftUI
import VibeApplication
import VibeDomain

/// The notes of the selected session, in a plain-text view that behaves like every text view on
/// the Mac: its shortcuts, its find bar, its undo — kept per session — and links that open.
///
/// An `NSTextView` rather than `TextEditor`: on macOS 14 the latter has neither clickable links,
/// nor an undo manager of its own per document, nor a find bar. TextKit 1, because one text
/// storage shared by several views — the same session in two windows — is its ordinary case.
struct SessionNotesEditor: NSViewRepresentable {
  let document: NotesDocument
  let isEditable: Bool
  let label: String
  let wantsFocus: Bool
  let focusTaken: () -> Void
  let openLink: (URL) -> Void
  /// Escape: the keyboard goes back to the terminal.
  let leave: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = Self.makeTextView()
    textView.delegate = context.coordinator

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.contentView.drawsBackground = false
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  /// A plain-text view that leaves what is typed alone.
  static func makeTextView() -> NSTextView {
    let textView = NSTextView(usingTextLayoutManager: false)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    // A note holds commands and branch names: `--force` must not become `—force`.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = true
    // Links are found by `NotesLinks`, with the schemes it allows, and never stored.
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.drawsBackground = false
    textView.font = NotesStyle.font
    textView.textColor = .textColor
    textView.typingAttributes = NotesStyle.attributes
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    return textView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard let textView = coordinator.textView else { return }
    coordinator.attach(document, to: textView)
    textView.isEditable = isEditable
    textView.setAccessibilityLabel(label)
    if wantsFocus {
      coordinator.takeFocus(in: textView, attempts: 5)
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    // The document outlives the view: detach it from this layout manager so the next view can
    // show it, and write what was typed.
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SessionNotesEditor?
    weak var textView: NSTextView?
    private var document: NotesDocument?
    private var lastEdit: NSRange?
    private var isNormalizing = false

    func attach(_ next: NotesDocument, to textView: NSTextView) {
      guard document !== next else { return }
      if let document {
        document.selection = textView.selectedRange()
        Task { await document.save() }
      }
      document = next
      // Typing is grouped into one undo action as long as nothing breaks it: left open, the next
      // session's first keystrokes would join the action registered in this one's undo manager.
      textView.breakUndoCoalescing()
      textView.layoutManager?.replaceTextStorage(next.storage)
      textView.typingAttributes = NotesStyle.attributes
      let length = next.storage.length
      let selection = next.selection
      let restored =
        selection.location <= length && NSMaxRange(selection) <= length
        ? selection : NSRange(location: length, length: 0)
      textView.setSelectedRange(restored)
      textView.scrollRangeToVisible(restored)
    }

    func detach() {
      guard let document, let textView else { return }
      document.selection = textView.selectedRange()
      textView.breakUndoCoalescing()
      // The actions recorded so far act through this text view, which is going away: kept, a ⌘Z
      // in the next one would do nothing, or edit a layout manager nothing shows any more.
      document.undoManager.removeAllActions()
      // An empty storage of its own, so the document's is held by one layout manager fewer.
      textView.layoutManager?.replaceTextStorage(NSTextStorage())
      self.document = nil
      Task { await document.save() }
    }

    func takeFocus(in textView: NSTextView, attempts: Int) {
      DispatchQueue.main.async { [weak self, weak textView] in
        guard let self, let textView else { return }
        guard let window = textView.window else {
          // Just unfolded: the inspector is not in the window yet.
          if attempts > 0 { self.takeFocus(in: textView, attempts: attempts - 1) }
          return
        }
        window.makeFirstResponder(textView)
        let end = NSRange(location: textView.string.utf16.count, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        self.parent?.focusTaken()
      }
    }

    // MARK: NSTextViewDelegate

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      // `nil`: attributes only, which a plain-text view only changes itself.
      guard let replacement = replacementString, let document else { return true }
      // In UTF-16: as a `String`, "\r\n" is one character, and `contains("\r")` says no.
      if !isNormalizing, replacement.utf16.contains(13) {
        // Pasted from Windows or an old Mac document: stored with the line endings of the file.
        let normalized = replacement.replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\r", with: "\n")
        isNormalizing = true
        textView.insertText(normalized, replacementRange: affectedCharRange)
        isNormalizing = false
        return false
      }
      guard document.shouldChange(in: affectedCharRange, replacement: replacement) else {
        NSSound.beep()
        return false
      }
      lastEdit = NSRange(location: affectedCharRange.location, length: replacement.utf16.count)
      return true
    }

    func textDidChange(_ notification: Notification) {
      guard let document else { return }
      if let lastEdit {
        NotesLinks.apply(to: document.storage, around: lastEdit)
      }
      lastEdit = nil
      document.didChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView, let document else { return }
      document.selection = textView.selectedRange()
    }

    func textDidEndEditing(_ notification: Notification) {
      guard let document else { return }
      Task { await document.save() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      document?.undoManager
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
      guard let url else { return false }
      parent?.openLink(url)
      return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      textView.window?.makeFirstResponder(nil)
      parent?.leave()
      return true
    }
  }
}

/// The notes section: its header and state, the editor, and what it has to say about the size.
struct SessionNotesSection: View {
  let session: WorkSession
  let document: NotesDocument
  let notes: NotesModel
  let leave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("Notes")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        NotesStateLabel(document: document)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)

      ZStack(alignment: .topLeading) {
        SessionNotesEditor(
          document: document,
          isEditable: document.isLoaded,
          label: "Notes for \(session.name)",
          wantsFocus: notes.wantsFocus,
          focusTaken: { notes.focusTaken() },
          openLink: { notes.openLink($0) },
          leave: leave
        )
        if document.isLoaded, document.byteCount == 0 {
          Text("Decisions, links, what to check next — saved automatically.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        if case .unreadable(let reason) = document.state {
          NotesUnreadable(
            reason: reason, text: document.text, sessionID: session.id, notes: notes)
        }
      }
      .frame(minHeight: 80, maxHeight: .infinity)
      .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
      .padding(.horizontal, 8)

      if let footer = NotesFooter.text(refusal: document.refusal, byteCount: document.byteCount) {
        Text(footer)
          .font(.caption)
          .foregroundStyle(document.refusal == nil ? Color.secondary : Color.orange)
          .padding(.horizontal, 12)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.bottom, 6)
  }
}

enum NotesFooter {
  /// A refused change first — it is what just happened — then how close the notes are to the limit.
  static func text(refusal: String?, byteCount: Int) -> String? {
    if let refusal { return refusal }
    guard byteCount >= SessionNotesLimits.warningByteCount else { return nil }
    return
      "\(SessionNotesError.size(byteCount)) of \(SessionNotesError.size(SessionNotesLimits.byteLimit))"
  }
}

/// Saved, Edited, Saving…, Not saved, Unreadable — in words, never by a colour alone.
struct NotesStateLabel: View {
  let document: NotesDocument
  @State private var showsSaving = false
  @State private var showsLoading = false
  @State private var isShowingFailure = false

  var body: some View {
    let presentation = NotesStatePresentation(state: document.state, showsSaving: showsSaving)
    Group {
      if presentation.isFailure {
        Button {
          isShowingFailure = true
        } label: {
          Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingFailure) {
          NotesFailureDetail(document: document)
        }
      } else if presentation.isUnreadable {
        Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      } else if case .loading = document.state {
        if showsLoading { ProgressView().controlSize(.mini) }
      } else {
        Text(presentation.title)
          .foregroundStyle(.secondary)
          .help(presentation.help ?? "")
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(presentation.accessibilityLabel)
    // Shown only when a write takes long enough to be noticed: otherwise every pause in the
    // typing would flash a word between Edited and Saved.
    .task(id: document.state) {
      showsSaving = false
      showsLoading = false
      switch document.state {
      case .saving:
        try? await Task.sleep(for: .milliseconds(300))
        if case .saving = document.state { showsSaving = true }
      case .loading:
        try? await Task.sleep(for: .milliseconds(200))
        if case .loading = document.state { showsLoading = true }
      default:
        break
      }
    }
    // Said aloud only when it matters: a write that failed, and the first one that succeeds after.
    .onChange(of: document.state) { previous, state in
      guard let announcement = NotesStatePresentation.announcement(from: previous, to: state)
      else { return }
      AccessibilityNotification.Announcement(announcement).post()
    }
  }
}

/// What the header says of a state. Pure, so every wording is tested without a view.
struct NotesStatePresentation: Equatable {
  let title: String
  let help: String?
  let accessibilityLabel: String
  let isFailure: Bool
  let isUnreadable: Bool

  init(state: NotesSaveState, showsSaving: Bool) {
    var help: String?
    var isFailure = false
    var isUnreadable = false
    switch state {
    case .loading:
      title = ""
      accessibilityLabel = "Loading notes"
    case .saved(nil):
      // Never written: there is nothing to report as saved.
      title = ""
      accessibilityLabel = "No notes yet"
    case .saved(let date?):
      title = "Saved"
      help = "Saved at \(Self.time(date))"
      accessibilityLabel = "Notes saved"
    case .edited:
      title = "Edited"
      help = "Saved a moment after you stop typing"
      accessibilityLabel = "Notes edited, not yet saved"
    case .saving:
      title = showsSaving ? "Saving…" : "Edited"
      accessibilityLabel = "Saving notes"
    case .failed(let error, _):
      title = "Not saved"
      accessibilityLabel = "Notes not saved: \(Self.sentence(error))"
      isFailure = true
    case .unreadable(let reason):
      title = "Unreadable"
      accessibilityLabel = "Notes unreadable: \(reason)"
      isUnreadable = true
    }
    self.help = help
    self.isFailure = isFailure
    self.isUnreadable = isUnreadable
  }

  /// What VoiceOver announces on a change of state, if anything: every save would be noise.
  static func announcement(from previous: NotesSaveState, to state: NotesSaveState) -> String? {
    switch (previous, state) {
    case (.failed, .failed):
      return nil
    case (_, .failed(let error, _)):
      return "Notes not saved: \(sentence(error))"
    case (.failed, .saved):
      return "Notes saved"
    default:
      return nil
    }
  }

  static func sentence(_ error: SessionNotesError) -> String {
    switch error {
    case .cannotWrite(let reason), .unreadable(let reason):
      return reason
    case .tooLarge:
      return error.localizedDescription
    }
  }

  static func time(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }
}

private struct NotesFailureDetail: View {
  let document: NotesDocument

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .failed(let error, let retryAt) = document.state {
        Text("The notes could not be saved: \(NotesStatePresentation.sentence(error))")
          .fixedSize(horizontal: false, vertical: true)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
          Text(seconds > 0 ? "Retrying in \(seconds) s." : "Retrying…")
            .foregroundStyle(.secondary)
        }
        Text("What you typed is kept until it is saved.")
          .foregroundStyle(.secondary)
      } else {
        Text("The notes are saved.")
      }
      HStack {
        Button("Copy Notes") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(document.text, forType: .string)
        }
        Button("Retry Now") {
          Task { await document.save() }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .font(.callout)
    .padding(14)
    .frame(width: 280)
  }
}

private struct NotesUnreadable: View {
  let reason: String
  let text: String
  let sessionID: SessionID
  let notes: NotesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("These notes could not be read", systemImage: "exclamationmark.triangle")
        .font(.callout.weight(.semibold))
      Text("\(reason) The file is left untouched, so nothing in it is lost.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if let url = notes.fileURL(for: sessionID) {
          Button("Reveal in Finder") { notes.reveal(url) }
        }
        // Read before it failed, typed since: the text is still in the editor, only not on disk.
        if !text.isEmpty {
          Button("Copy Notes") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          }
        }
      }
      .controlSize(.small)
    }
    .padding(10)
  }
}
