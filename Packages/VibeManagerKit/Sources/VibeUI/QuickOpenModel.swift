import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Open Quickly, ⌘P (#37): what is typed, what it found, which row is selected.
///
/// The search runs on the index's actor, never on the main thread. Each keystroke cancels the one
/// before it, and only the latest answer is shown: a slow answer to an older query never replaces
/// a newer one.
@MainActor
@Observable
public final class QuickOpenModel {
  public private(set) var isPresented = false
  public private(set) var text = ""
  public private(set) var answer: QuickOpenAnswer?
  public private(set) var selectedIndex = 0
  /// Journals read so far at launch, while they are being read.
  public private(set) var indexing: (done: Int, total: Int)?
  /// Bumped to select the whole field: ⌘P while the palette is open.
  public private(set) var selectAllRequest = 0

  @ObservationIgnored let index: SessionSearchIndex
  @ObservationIgnored private var search: Task<Void, Never>?
  @ObservationIgnored private var announcement: Task<Void, Never>?
  @ObservationIgnored private var loading: Task<Void, Never>?
  /// The last change handed to the index. Each one waits for the one before it: an older list
  /// arriving after a newer one would bring back a session just archived or deleted.
  @ObservationIgnored private var updating: Task<Void, Never>?
  /// The session on screen when the palette opened, left out of the recent ones.
  @ObservationIgnored private var excluded: SessionID?
  /// Where the keyboard was before the palette took it, given back when it closes unanswered.
  @ObservationIgnored weak var previousResponder: NSResponder?
  /// The text the answer on screen was searched for.
  @ObservationIgnored private var answeredText: String?
  /// Return pressed before the answer to what was typed arrived: it opens that answer's first row.
  @ObservationIgnored private var confirmsWhenAnswered = false
  /// Brings a session chosen on screen.
  @ObservationIgnored var opened: ((QuickOpenResult) -> Void)?
  /// How long the palette waits for the typing to pause before saying the count to VoiceOver.
  @ObservationIgnored var announcementDelay: Duration = .milliseconds(500)

  public init(index: SessionSearchIndex = SessionSearchIndex()) {
    self.index = index
  }

  public var results: [QuickOpenResult] { answer?.results ?? [] }

  public var selectedResult: QuickOpenResult? {
    results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
  }

  // MARK: - Keeping the index current

  func sessionsChanged(_ sessions: [WorkSession]) {
    enqueue { index in await index.update(sessions: sessions) }
  }

  func journalChanged(_ journal: SessionJournal, for id: SessionID) {
    enqueue { index in await index.update(journal: journal, for: id) }
  }

  private func enqueue(_ change: @escaping @Sendable (SessionSearchIndex) async -> Void) {
    let previous = updating
    updating = Task { [index] in
      await previous?.value
      await change(index)
    }
  }

  /// Reads every session's journal once, in the background.
  func loadJournals(
    for ids: [SessionID], read: @escaping @Sendable (SessionID) async -> SessionJournal?
  ) {
    guard loading == nil, !ids.isEmpty else { return }
    let progress: @Sendable (Int, Int) async -> Void = { [weak self] done, total in
      await self?.indexingProgressed(done: done, total: total)
    }
    loading = Task { [index] in
      await index.loadJournals(for: ids, read: read, progress: progress)
    }
  }

  private func indexingProgressed(done: Int, total: Int) {
    indexing = done < total ? (done, total) : nil
    // What was found so far is searched again with what has just arrived.
    if isPresented, done == total { refresh() }
  }

  // MARK: - Opening and closing

  /// Opens the palette, on the recent sessions, or selects its text when it is already open.
  func present(excluding selected: SessionID?, notes: [SessionID: String]) {
    guard !isPresented else {
      selectAllRequest += 1
      return
    }
    excluded = selected
    previousResponder = Self.owner(of: NSApp?.keyWindow?.firstResponder)
    text = ""
    answer = nil
    answeredText = nil
    confirmsWhenAnswered = false
    selectedIndex = 0
    isPresented = true
    let index = index
    search?.cancel()
    search = Task { [weak self] in
      await index.update(notes: notes)
      await self?.run("")
    }
  }

  /// A text field being edited holds the keyboard through the window's shared field editor, which
  /// the palette's own field takes over: the field is what gets the keyboard back.
  static func owner(of responder: NSResponder?) -> NSResponder? {
    if let editor = responder as? NSTextView, editor.isFieldEditor,
      let field = editor.delegate as? NSView
    {
      return field
    }
    return responder
  }

  /// Closes the palette. `restoringFocus` when nothing was chosen: the keyboard goes back where
  /// it was.
  func dismiss(restoringFocus: Bool) {
    guard isPresented else { return }
    isPresented = false
    confirmsWhenAnswered = false
    search?.cancel()
    announcement?.cancel()
    if restoringFocus, let responder = previousResponder, let window = NSApp?.keyWindow {
      window.makeFirstResponder(responder)
    }
    previousResponder = nil
  }

  // MARK: - Typing and moving

  func setText(_ text: String) {
    guard text != self.text else { return }
    self.text = text
    refresh()
  }

  private func refresh() {
    search?.cancel()
    let typed = text
    search = Task { [weak self] in await self?.run(typed) }
  }

  private func run(_ typed: String) async {
    // A search sees every change handed to the index before it.
    await updating?.value
    let answer = await index.search(typed, excluding: excluded)
    guard !Task.isCancelled, isPresented, typed == text else { return }
    // The same text searched again — the journals finished loading — keeps the row the user was on.
    let kept = typed == answeredText ? selectedResult?.sessionID : nil
    self.answer = answer
    answeredText = typed
    selectedIndex = kept.flatMap { id in answer.results.firstIndex { $0.sessionID == id } } ?? 0
    if confirmsWhenAnswered {
      confirmsWhenAnswered = false
      confirm()
      return
    }
    scheduleAnnouncement()
  }

  func moveSelection(by offset: Int) {
    guard !results.isEmpty else { return }
    let target = min(max(selectedIndex + offset, 0), results.count - 1)
    guard target != selectedIndex else { return }
    selectedIndex = target
    announcement?.cancel()
  }

  func select(_ id: SessionID) {
    guard let position = results.firstIndex(where: { $0.sessionID == id }) else { return }
    selectedIndex = position
  }

  /// Return: the selected session is brought on screen, and the palette closes. Pressed before
  /// the answer to what was typed arrived — a URL pasted and Return at once — it waits for it: the
  /// rows on screen answer an older text.
  func confirm() {
    guard answeredText == text else {
      confirmsWhenAnswered = true
      return
    }
    guard let result = selectedResult else { return }
    // An archived session is in no list of the sidebar: the keyboard goes back where it was.
    dismiss(restoringFocus: result.isArchived)
    opened?(result)
  }

  /// The count, said once the typing pauses: never at each keystroke.
  private func scheduleAnnouncement() {
    announcement?.cancel()
    guard !text.isEmpty else { return }
    let count = results.count
    let delay = announcementDelay
    announcement = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, self?.isPresented == true else { return }
      Announcer.announce(QuickOpenPresentation.countAnnouncement(count))
    }
  }
}
