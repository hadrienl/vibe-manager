import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Where a session's notes stand between what is typed and what is on disk.
public enum NotesSaveState: Equatable, Sendable {
  case loading
  /// On disk. `at` is when they were last written; `nil` when they never were.
  case saved(at: Date?)
  /// Typed, not yet written.
  case edited
  case saving
  /// The last write failed. The text is still in memory, and is written again at `retryAt`.
  case failed(SessionNotesError, retryAt: Date)
  /// The file could not be read, so nothing is shown and nothing will be written over it.
  case unreadable(reason: String)
}

/// How soon notes are written.
public struct NotesSaveTiming: Sendable {
  /// After the last keystroke.
  public var idle: Duration
  /// After the first change not yet written, however long the typing goes on.
  public var maximum: Duration
  public var firstRetry: Duration
  public var maximumRetry: Duration

  public init(
    idle: Duration = .seconds(1),
    maximum: Duration = .seconds(5),
    firstRetry: Duration = .seconds(1),
    maximumRetry: Duration = .seconds(30)
  ) {
    self.idle = idle
    self.maximum = maximum
    self.firstRetry = firstRetry
    self.maximumRetry = maximumRetry
  }
}

/// Waits out a delay. Injected so the timing can be tested without waiting for real.
public typealias NotesSleep = @Sendable (Duration) async throws -> Void

/// The notes of one session for the length of the run: the text every editor shows, the undo
/// history that goes with it, and the writes that take it to disk.
///
/// One per session, never per view: two windows on the same session edit one text storage, and
/// ⌘Z in one session can never undo a keystroke typed in another.
@MainActor
@Observable
public final class NotesDocument {
  public let sessionID: SessionID
  public private(set) var state: NotesSaveState = .loading
  /// The weight of the text in UTF-8, which is what the limit is about.
  public private(set) var byteCount = 0
  /// Why the last change was refused, until the next one is accepted.
  public private(set) var refusal: String?

  @ObservationIgnored let storage = NSTextStorage()
  @ObservationIgnored let undoManager = UndoManager()
  /// Where the cursor was, so that coming back to the session finds it there.
  @ObservationIgnored var selection = NSRange(location: 0, length: 0)
  /// Told of every change, with the new text: the search index keeps up with the typing.
  @ObservationIgnored var onChange: ((String) -> Void)?

  @ObservationIgnored private let store: any SessionNotesStore
  @ObservationIgnored private let timing: NotesSaveTiming
  @ObservationIgnored private let sleep: NotesSleep
  @ObservationIgnored private let now: @MainActor () -> Date
  /// Every change bumps it; a write records the one it carried. The two differ exactly while
  /// something typed is not yet on disk.
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var savedRevision = 0
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private var maximumTask: Task<Void, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var writeTask: Task<Bool, Never>?
  @ObservationIgnored private var retryDelay: Duration

  init(
    sessionID: SessionID,
    store: any SessionNotesStore,
    timing: NotesSaveTiming,
    sleep: @escaping NotesSleep,
    now: @escaping @MainActor () -> Date
  ) {
    self.sessionID = sessionID
    self.store = store
    self.timing = timing
    self.sleep = sleep
    self.now = now
    retryDelay = timing.firstRetry
  }

  public var text: String { storage.string }

  public var isLoaded: Bool {
    switch state {
    case .loading, .unreadable: return false
    default: return true
    }
  }

  public var hasUnsavedChanges: Bool { revision != savedRevision }

  /// Reads the notes from disk into the text storage, once.
  func load() async {
    do {
      let notes = try await store.notes(for: sessionID)
      guard case .loading = state else { return }
      storage.setAttributedString(
        NSAttributedString(string: notes.text, attributes: NotesStyle.attributes))
      NotesLinks.apply(to: storage, around: NSRange(location: 0, length: storage.length))
      byteCount = notes.text.utf8.count
      state = .saved(at: notes.modifiedAt)
    } catch {
      state = .unreadable(reason: Self.reason(error))
    }
  }

  // MARK: - Editing

  /// Whether replacing `range` with `replacement` keeps the notes within their limit.
  ///
  /// A change that would not is refused whole, and said: cutting the end off a paste would lose
  /// text without anyone seeing where.
  func shouldChange(in range: NSRange, replacement: String) -> Bool {
    guard isLoaded else { return false }
    let current = storage.string as NSString
    let clamped = NSIntersectionRange(range, NSRange(location: 0, length: current.length))
    let removed = current.substring(with: clamped).utf8.count
    let next = byteCount - removed + replacement.utf8.count
    guard next <= SessionNotesLimits.byteLimit || next <= byteCount else {
      refusal = String(
        localized: """
          This would make the notes \(SessionNotesError.size(next)); they are limited to \
          \(SessionNotesError.size(SessionNotesLimits.byteLimit)).
          """,
        bundle: .module, comment: "Two sizes, formatted: “70 KB”, “64 KB”.")
      return false
    }
    refusal = nil
    return true
  }

  /// Called once the text storage holds the change.
  func didChange() {
    byteCount = storage.string.utf8.count
    revision += 1
    switch state {
    case .failed, .unreadable, .loading: break
    default: state = .edited
    }
    onChange?(storage.string)
    scheduleSave()
  }

  // MARK: - Saving

  /// Writes what is not yet on disk, now, and waits for it.
  ///
  /// - Returns: whether everything typed is on disk.
  @discardableResult
  public func save() async -> Bool {
    while true {
      if let writeTask {
        _ = await writeTask.value
        continue
      }
      guard revision != savedRevision else { return true }
      if case .unreadable = state { return false }
      let task = Task { @MainActor () -> Bool in
        let succeeded = await self.write()
        self.writeTask = nil
        return succeeded
      }
      writeTask = task
      guard await task.value else { return false }
    }
  }

  private func scheduleSave() {
    idleTask?.cancel()
    idleTask = Task { [weak self, sleep, timing] in
      try? await sleep(timing.idle)
      guard !Task.isCancelled else { return }
      await self?.save()
    }
    if maximumTask == nil {
      maximumTask = Task { [weak self, sleep, timing] in
        try? await sleep(timing.maximum)
        guard !Task.isCancelled else { return }
        await self?.save()
      }
    }
  }

  /// One write of the text as it is now. Writes never overlap: `save` waits for the one in flight.
  private func write() async -> Bool {
    let carried = revision
    let text = storage.string
    for task in [idleTask, maximumTask, retryTask] { task?.cancel() }
    idleTask = nil
    maximumTask = nil
    retryTask = nil
    if case .failed = state {
    } else {
      state = .saving
    }

    do {
      let saved = try await store.save(text, for: sessionID)
      savedRevision = carried
      retryDelay = timing.firstRetry
      // Typed during the write: still edited, and the keystroke already scheduled the next one.
      state = carried == revision ? .saved(at: saved.modifiedAt ?? now()) : .edited
      return true
    } catch {
      let failure = error as? SessionNotesError ?? .cannotWrite(reason: Self.reason(error))
      if case .unreadable(let reason) = failure {
        state = .unreadable(reason: reason)
        return false
      }
      let delay = retryDelay
      retryDelay = min(retryDelay * 2, timing.maximumRetry)
      state = .failed(failure, retryAt: now().addingTimeInterval(Self.seconds(delay)))
      retryTask = Task { [weak self, sleep] in
        try? await sleep(delay)
        guard !Task.isCancelled else { return }
        await self?.save()
      }
      return false
    }
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }

  private static func reason(_ error: Error) -> String {
    if let error = error as? SessionNotesError {
      switch error {
      case .unreadable(let reason), .cannotWrite(let reason): return reason
      case .tooLarge: return error.localizedDescription
      }
    }
    return error.localizedDescription
  }
}

/// Every session's notes for the length of the run, and what the rest of the workspace needs of
/// them: the search, the summaries, the focus, the quit.
@MainActor
@Observable
public final class NotesModel {
  /// Every session's notes, for the search: read from disk at launch, then kept up with the typing.
  public private(set) var searchIndex: [SessionID: String] = [:]
  /// Set by Edit Notes, and cleared by the editor once it holds the keyboard.
  public private(set) var wantsFocus = false

  @ObservationIgnored private var documents: [SessionID: NotesDocument] = [:]
  @ObservationIgnored private var importTask: Task<Void, Never>?
  @ObservationIgnored private let store: any SessionNotesStore
  @ObservationIgnored private let timing: NotesSaveTiming
  @ObservationIgnored private let sleep: NotesSleep
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored let opener: (any FileOpening)?
  @ObservationIgnored private let fileLocation: (@Sendable (SessionID) -> URL)?

  init(
    store: any SessionNotesStore = NoSessionNotes(),
    fileLocation: (@Sendable (SessionID) -> URL)? = nil,
    timing: NotesSaveTiming = NotesSaveTiming(),
    sleep: @escaping NotesSleep = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Date = { Date() },
    opener: (any FileOpening)? = nil
  ) {
    self.store = store
    self.fileLocation = fileLocation
    self.timing = timing
    self.sleep = sleep
    self.now = now
    self.opener = opener
  }

  /// Imports the notes an older store held inside its sessions, then reads every session's notes
  /// for the search. Off the main thread for the reading; never in the way of the session list.
  ///
  /// The import is registered before this returns: a document opened meanwhile waits for it,
  /// rather than reading the disk before the imported file is there — it would show no notes, and
  /// its first keystroke would write over the ones just imported.
  @discardableResult
  func startPreparing(importing legacy: ImportLegacyNotes?) -> Task<Void, Never> {
    let importing = Task { _ = await legacy?() }
    importTask = importing
    return Task { await self.readIndex(after: importing) }
  }

  func prepare(importing legacy: ImportLegacyNotes?) async {
    await startPreparing(importing: legacy).value
  }

  private func readIndex(after importing: Task<Void, Never>) async {
    await importing.value
    let all = await store.allNotes()
    // A document already open knows better than the disk: it may hold what was just typed.
    var index = all
    for (id, document) in documents where document.isLoaded {
      index[id] = document.text.isEmpty ? nil : document.text
    }
    searchIndex = index
  }

  /// The notes of a session, read from disk the first time they are asked for.
  public func document(for id: SessionID) -> NotesDocument {
    if let document = documents[id] { return document }
    let document = NotesDocument(
      sessionID: id, store: store, timing: timing, sleep: sleep, now: now)
    document.onChange = { [weak self] text in
      self?.searchIndex[id] = text.isEmpty ? nil : text
    }
    documents[id] = document
    let importing = importTask
    Task {
      _ = await importing?.value
      await document.load()
    }
    return document
  }

  /// The notes to hand an agent: what is in the editor, or what was read at launch.
  public func text(for id: SessionID) -> String? {
    if let document = documents[id], document.isLoaded {
      return document.text.isEmpty ? nil : document.text
    }
    return searchIndex[id]
  }

  /// Writes what is pending for one session, now.
  @discardableResult
  public func flush(_ id: SessionID) async -> Bool {
    guard let document = documents[id] else { return true }
    return await document.save()
  }

  /// Writes what is pending everywhere, now.
  ///
  /// - Returns: the documents still not on disk afterwards, in no particular order.
  public func flushAll() async -> [NotesDocument] {
    var unsaved: [NotesDocument] = []
    for document in documents.values where document.hasUnsavedChanges {
      if await !document.save() { unsaved.append(document) }
    }
    return unsaved
  }

  /// `flushAll`, bounded: a write stuck on a stalled volume must not keep the application from
  /// quitting. What is not on disk when the time is up is reported as unsaved.
  public func flushAll(deadline: Duration) async -> [NotesDocument] {
    let once = Once()
    return await withCheckedContinuation { continuation in
      Task { @MainActor in
        let unsaved = await self.flushAll()
        if once.claim() { continuation.resume(returning: unsaved) }
      }
      Task { @MainActor in
        try? await Task.sleep(for: deadline)
        if once.claim() { continuation.resume(returning: self.unsavedDocuments) }
      }
    }
  }

  /// Every document with something typed that is not on disk.
  public var unsavedDocuments: [NotesDocument] {
    documents.values.filter(\.hasUnsavedChanges)
  }

  /// Where a session's notes are on disk, for Reveal in Finder. `nil` for a store with no files.
  func fileURL(for id: SessionID) -> URL? {
    fileLocation?(id)
  }

  func reveal(_ url: URL) {
    if let opener {
      opener.reveal(url)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func requestFocus() {
    wantsFocus = true
  }

  func focusTaken() {
    wantsFocus = false
  }

  /// Opens a link clicked in the notes. A file is revealed rather than opened: a click in a note
  /// must not launch whatever a document happens to be associated with.
  func openLink(_ url: URL) {
    guard NotesLinks.isAllowed(url) else { return }
    if url.isFileURL {
      reveal(url)
      return
    }
    guard let opener else {
      NSWorkspace.shared.open(url)
      return
    }
    Task { _ = await opener.open(url, with: .defaultApplication) }
  }
}

/// What a summary sheet says of notes it had to leave out.
enum NotesInSummary {
  /// "Notes left out: too long for the summary (18 KB)." — or `nil` when the notes are in it, or
  /// there are none. The agent will not read them, and the user can still paste what matters.
  static func leftOut(notes: String?, brief: SessionContextBrief?) -> String? {
    guard let brief, let notes else { return nil }
    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !brief.includedSections.contains(.notes) else { return nil }
    return String(
      localized: """
        Notes left out: too long for the summary (\(SessionNotesError.size(trimmed.utf8.count))). \
        Paste what matters into the summary above.
        """,
      bundle: .module, comment: "A size, formatted: “18 KB”.")
  }
}

/// Lets exactly one of two racers answer.
@MainActor
private final class Once {
  private var isClaimed = false

  func claim() -> Bool {
    guard !isClaimed else { return false }
    isClaimed = true
    return true
  }
}

/// How notes look in the editor.
enum NotesStyle {
  static var font: NSFont { NSFont.preferredFont(forTextStyle: .callout) }

  static var attributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.textColor]
  }
}

/// Links in the notes: found where they are shown, never written to the file.
enum NotesLinks {
  /// A click in a note must not launch an application through a custom scheme.
  static let allowedSchemes: Set<String> = ["http", "https", "mailto", "file"]

  static func isAllowed(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return allowedSchemes.contains(scheme)
  }

  /// The links of `text`, as ranges in its UTF-16 view.
  static func links(in text: String) -> [(range: NSRange, url: URL)] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }
    let whole = NSRange(location: 0, length: (text as NSString).length)
    return detector.matches(in: text, range: whole).compactMap { match in
      guard let url = match.url, isAllowed(url) else { return nil }
      return (match.range, url)
    }
  }

  /// Finds the links again in the paragraphs `range` touches.
  static func apply(to storage: NSTextStorage, around range: NSRange) {
    let string = storage.string as NSString
    let location = min(range.location, string.length)
    let length = min(range.length, string.length - location)
    let paragraphs = string.paragraphRange(for: NSRange(location: location, length: length))
    storage.beginEditing()
    storage.removeAttribute(.link, range: paragraphs)
    for link in links(in: string.substring(with: paragraphs)) {
      storage.addAttribute(
        .link, value: link.url,
        range: NSRange(
          location: paragraphs.location + link.range.location, length: link.range.length))
    }
    storage.endEditing()
  }
}
