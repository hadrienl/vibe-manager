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
  /// The session on screen when the palette opened, left out of the recent ones.
  @ObservationIgnored private var excluded: SessionID?
  /// Where the keyboard was before the palette took it, given back when it closes unanswered.
  @ObservationIgnored weak var previousResponder: NSResponder?
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
    Task { [index] in await index.update(sessions: sessions) }
  }

  func journalChanged(_ journal: SessionJournal, for id: SessionID) {
    Task { [index] in await index.update(journal: journal, for: id) }
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
    previousResponder = NSApp?.keyWindow?.firstResponder
    text = ""
    answer = nil
    selectedIndex = 0
    isPresented = true
    let index = index
    search?.cancel()
    search = Task { [weak self] in
      await index.update(notes: notes)
      await self?.run("")
    }
  }

  /// Closes the palette. `restoringFocus` when nothing was chosen: the keyboard goes back where
  /// it was.
  func dismiss(restoringFocus: Bool) {
    guard isPresented else { return }
    isPresented = false
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
    let answer = await index.search(typed, excluding: excluded)
    guard !Task.isCancelled, isPresented, typed == text else { return }
    self.answer = answer
    selectedIndex = 0
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

  /// The session Return opens. The palette closes.
  func confirm() -> SessionID? {
    guard let result = selectedResult else { return nil }
    dismiss(restoringFocus: false)
    return result.sessionID
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
