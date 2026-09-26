import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

/// Sleeps that only end when the test says so, so the timing is tested without waiting for it.
private final class ManualSleeper: @unchecked Sendable {
  private struct Waiter {
    let id: Int
    let duration: Duration
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var waiters: [Waiter] = []
  private var cancelled: Set<Int> = []
  private var nextID = 0

  var sleep: NotesSleep {
    { [self] duration in try await wait(duration) }
  }

  var pending: [Duration] {
    lock.withLock { waiters.map(\.duration).sorted() }
  }

  /// Ends every sleep of `duration`.
  func fire(_ duration: Duration) {
    let fired = lock.withLock {
      let fired = waiters.filter { $0.duration == duration }
      waiters.removeAll { $0.duration == duration }
      return fired
    }
    for waiter in fired { waiter.continuation.resume() }
  }

  private func wait(_ duration: Duration) async throws {
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let isCancelled = lock.withLock {
          if cancelled.contains(id) { return true }
          waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
          return false
        }
        if isCancelled { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let waiter = lock.withLock {
        cancelled.insert(id)
        let index = waiters.firstIndex { $0.id == id }
        return index.map { waiters.remove(at: $0) }
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  }
}

/// A store whose writes wait for the test to let them through.
private actor GatedNotesStore: SessionNotesStore {
  private var text: [SessionID: String] = [:]
  private var gates: [CheckedContinuation<Void, Never>] = []
  private(set) var writes: [String] = []

  func notes(for id: SessionID) -> SessionNotes {
    SessionNotes(text: text[id] ?? "", modifiedAt: nil)
  }

  func save(_ text: String, for id: SessionID) async -> SessionNotes {
    await withCheckedContinuation { gates.append($0) }
    self.text[id] = text
    writes.append(text)
    return SessionNotes(text: text, modifiedAt: Date())
  }

  func allNotes() -> [SessionID: String] { text }
  func importNotes(_ text: String, for id: SessionID) {}

  var waitingWrites: Int { gates.count }

  func release() {
    let gates = gates
    self.gates = []
    for gate in gates { gate.resume() }
  }
}

@MainActor
private func settle(_ condition: @MainActor () async -> Bool) async {
  for _ in 0..<2_000 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor
private func type(_ text: String, into document: NotesDocument) {
  let end = NSRange(location: document.storage.length, length: 0)
  guard document.shouldChange(in: end, replacement: text) else { return }
  document.storage.replaceCharacters(in: end, with: text)
  document.didChange()
}

@MainActor
private func isSaved(_ document: NotesDocument) -> Bool {
  if case .saved = document.state { return true }
  return false
}

@MainActor
@Suite("Saving the notes as they are typed")
struct NotesSavingTests {
  private let id = SessionID()

  private func make(
    _ store: any SessionNotesStore = InMemorySessionNotesStore()
  ) async -> (NotesModel, NotesDocument, ManualSleeper) {
    let sleeper = ManualSleeper()
    let model = NotesModel(store: store, sleep: sleeper.sleep)
    let document = model.document(for: id)
    await settle { document.isLoaded }
    return (model, document, sleeper)
  }

  @Test("A keystroke is written a second after the typing stops, once")
  func idleSave() async throws {
    let store = InMemorySessionNotesStore()
    let (_, document, sleeper) = await make(store)

    type("Keep lodash.", into: document)
    #expect(document.state == .edited)
    await settle { sleeper.pending == [.seconds(1), .seconds(5)] }
    #expect(sleeper.pending == [.seconds(1), .seconds(5)])

    sleeper.fire(.seconds(1))
    await settle { isSaved(document) }

    #expect(isSaved(document))
    #expect(await store.saveCount == 1)
    #expect(try await store.notes(for: id).text == "Keep lodash.")
    // The write took the five-second one with it.
    await settle { sleeper.pending.isEmpty }
    #expect(sleeper.pending.isEmpty)
  }

  @Test("Typing that goes on is still written every five seconds")
  func maximumDelay() async throws {
    let store = InMemorySessionNotesStore()
    let (_, document, sleeper) = await make(store)

    type("One", into: document)
    type(" two", into: document)
    type(" three", into: document)
    await settle { sleeper.pending == [.seconds(1), .seconds(5)] }
    // Each keystroke replaced the one-second wait; there is still only one of each.
    #expect(sleeper.pending == [.seconds(1), .seconds(5)])

    sleeper.fire(.seconds(5))
    await settle { isSaved(document) }

    #expect(await store.saveCount == 1)
    #expect(try await store.notes(for: id).text == "One two three")
  }

  @Test("Leaving the session writes at once, without waiting for the delay")
  func flushWritesNow() async throws {
    let store = InMemorySessionNotesStore()
    let (model, document, _) = await make(store)

    type("Before switching", into: document)
    #expect(await model.flush(id))

    #expect(isSaved(document))
    #expect(try await store.notes(for: id).text == "Before switching")
    #expect(!document.hasUnsavedChanges)
  }

  @Test("A write that fails keeps the text, says so, and tries again after 1, then 2 seconds")
  func failureRetries() async throws {
    let store = InMemorySessionNotesStore()
    await store.failWrites(with: .cannotWrite(reason: "the disk is full."))
    let (_, document, sleeper) = await make(store)

    type("Precious", into: document)
    await settle { sleeper.pending == [.seconds(1), .seconds(5)] }
    sleeper.fire(.seconds(1))
    await settle {
      if case .failed = document.state { return sleeper.pending == [.seconds(1)] }
      return false
    }
    guard case .failed(let error, _) = document.state else {
      Issue.record("Expected a failure, got \(document.state)")
      return
    }
    #expect(error == .cannotWrite(reason: "the disk is full."))
    #expect(document.text == "Precious")

    sleeper.fire(.seconds(1))
    await settle { sleeper.pending == [.seconds(2)] }
    #expect(sleeper.pending == [.seconds(2)])

    await store.failWrites(with: nil)
    sleeper.fire(.seconds(2))
    await settle { isSaved(document) }
    #expect(isSaved(document))
    #expect(try await store.notes(for: id).text == "Precious")
  }

  @Test("What is typed during a write is not announced as saved, and goes out in the next write")
  func typingDuringAWrite() async throws {
    let store = GatedNotesStore()
    let (_, document, _) = await make(store)

    type("A", into: document)
    let first = Task { await document.save() }
    await settle { await store.waitingWrites == 1 }
    type("B", into: document)
    await store.release()
    await settle { await store.writes == ["A"] }
    await settle { await store.waitingWrites == 1 }

    // The first write is done, but "B" is not on disk: still edited.
    #expect(document.hasUnsavedChanges)
    #expect(!isSaved(document))

    await store.release()
    #expect(await first.value)
    #expect(await store.writes == ["A", "AB"])
    #expect(isSaved(document))
  }

  @Test("A change that would go over the limit is refused whole, and said")
  func limitIsRefusedWhole() async throws {
    let (_, document, _) = await make()
    type("Short.", into: document)

    let paste = String(repeating: "x", count: SessionNotesLimits.byteLimit)
    #expect(!document.shouldChange(in: NSRange(location: 6, length: 0), replacement: paste))
    #expect(document.refusal?.contains("limited to") == true)
    #expect(document.text == "Short.")

    // Replacing the text with something within the limit is fine again, and clears the message.
    #expect(document.shouldChange(in: NSRange(location: 0, length: 6), replacement: "Ok"))
    #expect(document.refusal == nil)
  }

  @Test("Notes that cannot be read are shown as such, and cannot be edited")
  func unreadableNotes() async throws {
    let store = InMemorySessionNotesStore()
    await store.markUnreadable(id)
    let sleeper = ManualSleeper()
    let model = NotesModel(store: store, sleep: sleeper.sleep)
    let document = model.document(for: id)
    await settle { document.state != .loading }

    #expect(document.state == .unreadable(reason: "test"))
    #expect(!document.isLoaded)
    #expect(!document.shouldChange(in: NSRange(location: 0, length: 0), replacement: "x"))
  }

  @Test("Quitting waits for the notes only so long, and reports those still in flight")
  func flushAllHasADeadline() async throws {
    let store = GatedNotesStore()
    let (model, document, _) = await make(store)
    type("Stuck on a stalled volume", into: document)

    let unsaved = await model.flushAll(deadline: .milliseconds(50))

    #expect(unsaved.map(\.sessionID) == [id])
    await store.release()
  }

  @Test("A document opened during the import shows the imported notes, and keeps them")
  func documentWaitsForTheImport() async throws {
    let session = WorkSession(name: "Old", status: .closed, legacyNotes: "Written before #16")
    let repository = WorkspaceRepository(sessions: [session])
    let store = InMemorySessionNotesStore()
    let model = NotesModel(store: store, sleep: ManualSleeper().sleep)

    model.startPreparing(importing: ImportLegacyNotes(repository: repository, notes: store))
    let document = model.document(for: session.id)
    await settle { document.isLoaded }

    #expect(document.text == "Written before #16")
    #expect(try await store.notes(for: session.id).text == "Written before #16")
  }

  @Test("Quitting reports the notes that could still not be written")
  func flushAllReportsTheUnsaved() async throws {
    let store = InMemorySessionNotesStore()
    let (model, document, _) = await make(store)
    type("Unsaved", into: document)
    await store.failWrites(with: .cannotWrite(reason: "the disk is full."))

    let unsaved = await model.flushAll()

    #expect(unsaved.map(\.sessionID) == [id])
    #expect(model.unsavedDocuments.count == 1)
  }
}

@MainActor
@Suite("Searching and summarising with the notes")
struct NotesIndexTests {
  @Test("Every session's notes are read for the search, then follow the typing")
  func searchIndex() async throws {
    let first = SessionID()
    let second = SessionID()
    let store = InMemorySessionNotesStore(notes: [first: "Rolled back the refactoring"])
    let model = NotesModel(store: store, sleep: ManualSleeper().sleep)

    await model.prepare(importing: nil)
    #expect(model.searchIndex == [first: "Rolled back the refactoring"])

    let document = model.document(for: second)
    await settle { document.isLoaded }
    type("Keep lodash", into: document)

    #expect(model.searchIndex[second] == "Keep lodash")
    #expect(model.text(for: second) == "Keep lodash")
    #expect(model.text(for: first) == "Rolled back the refactoring")
  }

  @Test("The sidebar finds a session by a word of its notes, accents ignored")
  func sidebarSearchReachesTheNotes() async throws {
    let session = WorkSession(name: "Webhook", status: .closed)
    let other = WorkSession(name: "Docs", status: .closed)
    let repository = WorkspaceRepository(sessions: [session, other])
    let store = InMemorySessionNotesStore(notes: [session.id: "Le réfactoring est annulé"])
    let model = AppModel(repository: repository, notesStore: store)
    await model.load()
    await settle { !model.notes.searchIndex.isEmpty }

    model.setColumn(.done)
    model.setSearchText("refactoring")

    #expect(model.visibleSessions.map(\.id) == [session.id])
  }
}

@MainActor
@Suite("The notes editor")
struct NotesEditorTests {
  private func editor(
    for document: NotesDocument
  ) -> (NSTextView, SessionNotesEditor.Coordinator) {
    let textView = NSTextView(usingTextLayoutManager: false)
    textView.isRichText = false
    textView.allowsUndo = true
    let coordinator = SessionNotesEditor.Coordinator()
    textView.delegate = coordinator
    coordinator.textView = textView
    coordinator.attach(document, to: textView)
    return (textView, coordinator)
  }

  @Test("Undo belongs to a session: ⌘Z in one never touches the other")
  func undoIsPerSession() async throws {
    let model = NotesModel(store: InMemorySessionNotesStore(), sleep: ManualSleeper().sleep)
    let first = model.document(for: SessionID())
    let second = model.document(for: SessionID())
    await settle { first.isLoaded && second.isLoaded }
    let (textView, coordinator) = editor(for: first)

    textView.insertText("Typed in the first", replacementRange: textView.selectedRange())
    #expect(first.text == "Typed in the first")
    #expect(first.undoManager.canUndo)

    coordinator.attach(second, to: textView)
    #expect(textView.undoManager === second.undoManager)
    #expect(!second.undoManager.canUndo)
    #expect(textView.string.isEmpty)

    coordinator.attach(first, to: textView)
    first.undoManager.undo()
    #expect(first.text.isEmpty)
    #expect(second.text.isEmpty)
  }

  @Test("Windows line endings are stored as the file's own")
  func lineEndingsAreNormalized() async throws {
    let model = NotesModel(store: InMemorySessionNotesStore(), sleep: ManualSleeper().sleep)
    let document = model.document(for: SessionID())
    await settle { document.isLoaded }
    let (textView, _) = editor(for: document)

    textView.insertText("one\r\ntwo\rthree", replacementRange: textView.selectedRange())

    #expect(document.text == "one\ntwo\nthree")
  }

  @Test("A paste with Windows line endings only is stored with the file's own")
  func crlfOnlyIsNormalized() async throws {
    let model = NotesModel(store: InMemorySessionNotesStore(), sleep: ManualSleeper().sleep)
    let document = model.document(for: SessionID())
    await settle { document.isLoaded }
    let (textView, _) = editor(for: document)

    textView.insertText("one\r\ntwo\r\n", replacementRange: textView.selectedRange())

    #expect(document.text == "one\ntwo\n")
  }

  @Test("Coming back to a session puts the cursor back where it was")
  func selectionIsKept() async throws {
    let model = NotesModel(store: InMemorySessionNotesStore(), sleep: ManualSleeper().sleep)
    let first = model.document(for: SessionID())
    let second = model.document(for: SessionID())
    await settle { first.isLoaded && second.isLoaded }
    let (textView, coordinator) = editor(for: first)
    textView.insertText("Hello world", replacementRange: textView.selectedRange())
    textView.setSelectedRange(NSRange(location: 5, length: 0))

    coordinator.attach(second, to: textView)
    coordinator.attach(first, to: textView)

    #expect(textView.selectedRange() == NSRange(location: 5, length: 0))
  }

  @Test("Web and mail links are found; other schemes are not, and nothing reaches the file")
  func links() async throws {
    let text = "See https://github.com/x, mailto:dev@example.com, ftp://files.org and myapp://open."
    let found = NotesLinks.links(in: text).map { $0.url.scheme ?? "" }
    #expect(found == ["https", "mailto"])

    let store = InMemorySessionNotesStore()
    let model = NotesModel(store: store, sleep: ManualSleeper().sleep)
    let id = SessionID()
    let document = model.document(for: id)
    await settle { document.isLoaded }
    let (textView, _) = editor(for: document)
    textView.insertText(text, replacementRange: textView.selectedRange())

    var linked: [URL] = []
    document.storage.enumerateAttribute(
      .link, in: NSRange(location: 0, length: document.storage.length)
    ) { value, _, _ in
      if let url = value as? URL { linked.append(url) }
    }
    #expect(linked.map(\.absoluteString) == ["https://github.com/x", "mailto:dev@example.com"])

    #expect(await model.flush(id))
    #expect(try await store.notes(for: id).text == text)
  }

  @Test("Dashes and quotes are left as typed")
  func noSubstitutions() {
    let textView = SessionNotesEditor.makeTextView()

    #expect(!textView.isAutomaticDashSubstitutionEnabled)
    #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
    #expect(!textView.isAutomaticSpellingCorrectionEnabled)
    #expect(!textView.isRichText)
    #expect(textView.usesFindBar)
  }
}

@Suite("What the notes header says")
struct NotesStatePresentationTests {
  @Test("Each state is said in words, never by a colour alone")
  func wording() {
    #expect(NotesStatePresentation(state: .saved(at: nil), showsSaving: false).title == nil)
    #expect(
      english(NotesStatePresentation(state: .saved(at: Date()), showsSaving: false).title)
        == "Saved")
    #expect(english(NotesStatePresentation(state: .edited, showsSaving: false).title) == "Edited")
    #expect(english(NotesStatePresentation(state: .saving, showsSaving: false).title) == "Edited")
    #expect(english(NotesStatePresentation(state: .saving, showsSaving: true).title) == "Saving…")

    let failed = NotesStatePresentation(
      state: .failed(.cannotWrite(reason: "the disk is full."), retryAt: Date()),
      showsSaving: false)
    #expect(english(failed.title) == "Not saved")
    #expect(failed.isFailure)
    #expect(failed.accessibilityLabel == "Notes not saved: the disk is full.")

    let unreadable = NotesStatePresentation(
      state: .unreadable(reason: "the file is not UTF-8 text."), showsSaving: false)
    #expect(english(unreadable.title) == "Unreadable")
    #expect(unreadable.isUnreadable)
  }

  @Test("VoiceOver hears a failed write and the recovery from it, not every save")
  func announcements() {
    let failed = NotesSaveState.failed(.cannotWrite(reason: "the disk is full."), retryAt: Date())
    #expect(
      NotesStatePresentation.announcement(from: .edited, to: failed)
        == "Notes not saved: the disk is full.")
    #expect(NotesStatePresentation.announcement(from: failed, to: failed) == nil)
    #expect(
      NotesStatePresentation.announcement(from: failed, to: .saved(at: Date())) == "Notes saved")
    #expect(NotesStatePresentation.announcement(from: .saving, to: .saved(at: Date())) == nil)
  }

  @Test("The footer warns near the limit, and says a refused change first")
  func footer() {
    #expect(NotesFooter.text(refusal: nil, byteCount: 1_000) == nil)
    #expect(NotesFooter.text(refusal: nil, byteCount: 58 * 1024)?.contains("of") == true)
    #expect(NotesFooter.text(refusal: "Refused.", byteCount: 58 * 1024) == "Refused.")
  }
}

@Suite("Notes a summary had to leave out")
struct NotesInSummaryTests {
  private let session = WorkSession(name: "Audit deps", status: .closed)

  @Test("Notes too long for the summary are said to be left out, with their size")
  func leftOutIsSaid() {
    let long = String(repeating: "note ", count: 20_000)
    let brief = SessionContextBriefBuilder()(for: session, notes: long)

    let sentence = NotesInSummary.leftOut(notes: long, brief: brief)

    #expect(!brief.includedSections.contains(.notes))
    #expect(sentence?.hasPrefix("Notes left out: too long for the summary (") == true)
  }

  @Test("Notes that fit, and no notes at all, say nothing")
  func nothingToSay() {
    let brief = SessionContextBriefBuilder()(for: session, notes: "Keep lodash.")
    #expect(NotesInSummary.leftOut(notes: "Keep lodash.", brief: brief) == nil)
    #expect(NotesInSummary.leftOut(notes: "  ", brief: brief) == nil)
    #expect(NotesInSummary.leftOut(notes: nil, brief: brief) == nil)
    #expect(NotesInSummary.leftOut(notes: "Keep lodash.", brief: nil) == nil)
  }
}

private func english(_ title: LocalizedStringResource?) -> String? {
  title.map { Localization.string($0, in: "en") }
}
