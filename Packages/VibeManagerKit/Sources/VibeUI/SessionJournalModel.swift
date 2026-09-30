import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// A row of the Activity pane.
enum ActivityRowID: Hashable, Sendable {
  case entry(UUID)
  case resource(String)
}

/// The journal of every session as the Activity pane shows it (#36): its summary, its resources,
/// whether a summary is being written. Observed apart from Git: a line of the journal must not
/// redraw the file lists.
@MainActor
@Observable
public final class SessionJournalModel {
  /// How many of the latest entries are shown before "Show Earlier".
  static let pageSize = 30

  /// One cell per session (#254): the Activity pane of one session is not evaluated again when
  /// another's journal moves.
  @ObservationIgnored let journals = ObservedCells<SessionID, SessionJournal>()
  @ObservationIgnored let summarizing = ObservedCells<SessionID, Bool>()
  /// Sessions whose journal was asked of the store, found or not. No view reads it.
  @ObservationIgnored private var looked: Set<SessionID> = []
  private(set) var focusRequest = 0
  private var selections: [SessionID: ActivityRowID] = [:]
  private var shownEntries: [SessionID: Int] = [:]
  /// Said under the pane's header after a gesture that could not do all it was asked.
  private(set) var notice: String?

  public var summariesEnabled: Bool {
    didSet {
      guard summariesEnabled != oldValue else { return }
      preferences.summariesEnabled = summariesEnabled
      let enabled = summariesEnabled
      Task { [monitor] in await monitor.setSummariesEnabled(enabled) }
    }
  }

  @ObservationIgnored private let monitor: SessionJournalMonitor
  @ObservationIgnored private let preferences: any JournalPreferences
  @ObservationIgnored let opener: any FileOpening
  @ObservationIgnored private var updates: Task<Void, Never>?
  /// The last list of sessions handed to the monitor. Each waits for the one before it: an older
  /// list arriving after a newer one would follow a session just closed again.
  @ObservationIgnored private var tracking: Task<Void, Never>?
  /// Turns the settings window to the journal's tab, before it is opened.
  @ObservationIgnored var showSettingsTab: (() -> Void)?
  /// The editor chosen in the settings, for Open in Editor.
  @ObservationIgnored var editor: EditorChoice?
  /// Opens a link of a session as every link of it is (#186): where Settings say, ⌥ doing the other,
  /// or where its menu says. Unset, the default browser shows it.
  @ObservationIgnored var route: ((URL, LinkGesture, SessionID) -> Void)?
  /// Whether a session has a web view, for the menu of a link.
  @ObservationIgnored var hasWebView: ((SessionID) -> Bool)?
  /// Whether ⌥ is held, read when a link is clicked.
  @ObservationIgnored var isOptionKeyDown: () -> Bool = { NSEvent.modifierFlags.contains(.option) }
  /// Told of every journal that arrives, for Open Quickly's index (#37).
  @ObservationIgnored var journalDidChange: ((SessionID, SessionJournal) -> Void)?

  /// Reads the journal of any session, off the main thread: for the index of Open Quickly.
  var reader: @Sendable (SessionID) async -> SessionJournal? {
    let monitor = monitor
    return { await monitor.journal(for: $0) }
  }

  public convenience init(monitor: SessionJournalMonitor, preferences: any JournalPreferences) {
    self.init(monitor: monitor, preferences: preferences, opener: WorkspaceFileOpener())
  }

  init(
    monitor: SessionJournalMonitor, preferences: any JournalPreferences, opener: any FileOpening
  ) {
    self.monitor = monitor
    self.preferences = preferences
    self.opener = opener
    summariesEnabled = preferences.summariesEnabled
  }

  // MARK: - Following the monitor

  func start() async {
    guard updates == nil else { return }
    let stream = await monitor.updates()
    updates = Task { [weak self] in
      for await update in stream {
        guard let self else { return }
        // Open Quickly indexes a journal again only when it changed.
        if self.journals.set(update.journal, for: update.sessionID) {
          self.journalDidChange?(update.sessionID, update.journal)
        }
        self.looked.insert(update.sessionID)
        self.summarizing.set(update.isSummarizing ? true : nil, for: update.sessionID)
      }
    }
    await monitor.setSummariesEnabled(summariesEnabled)
  }

  /// Hands the monitor a list of sessions, after the lists handed before it. Chained here, on the
  /// main actor, so that the order the lists were made in is the order they arrive in.
  func track(_ sessions: [WorkSession]) {
    let previous = tracking
    tracking = Task { [monitor] in
      await previous?.value
      await monitor.track(sessions)
    }
  }

  func refresh() async {
    await monitor.refresh()
  }

  func stop() async {
    updates?.cancel()
    updates = nil
    await monitor.stop()
  }

  /// Reads the journal of a session not followed — closed or archived — once.
  func load(_ id: SessionID) {
    guard !looked.contains(id) else { return }
    looked.insert(id)
    Task { [weak self, monitor] in
      let journal = await monitor.journal(for: id)
      guard let self, let journal, self.journals.value(for: id) == nil else { return }
      self.journals.set(journal, for: id)
    }
  }

  func retry(_ id: SessionID) {
    Task { [monitor] in await monitor.retry(id) }
  }

  func journal(for id: SessionID) -> SessionJournal? {
    journals.value(for: id)
  }

  func isSummarizing(_ id: SessionID) -> Bool {
    summarizing.value(for: id) == true
  }

  // MARK: - Screen state

  func requestFocus() {
    focusRequest += 1
    isFocusPending = true
  }

  /// Set until the list has taken the keyboard. A request made while its section is folded is
  /// taken by the list that unfolding brings on screen, which never sees the bump itself (#66).
  private(set) var isFocusPending = false

  func focusTaken() {
    isFocusPending = false
  }

  func selection(in id: SessionID) -> ActivityRowID? {
    selections[id]
  }

  func select(_ row: ActivityRowID?, in id: SessionID) {
    selections[id] = row
  }

  func shownEntryCount(in id: SessionID) -> Int {
    shownEntries[id] ?? Self.pageSize
  }

  func showEarlier(in id: SessionID) {
    shownEntries[id] = shownEntryCount(in: id) + Self.pageSize
  }

  // MARK: - Gestures

  /// Return or a double click: the resource's page, its folder, its branch.
  func activate(_ row: ActivityRowID, in id: SessionID) {
    notice = nil
    switch row {
    case .resource(let key):
      guard let resource = journals.value(for: id)?.resources.first(where: { $0.key == key }) else {
        return
      }
      open(resource, from: id)
    case .entry(let entryID):
      guard let entry = journals.value(for: id)?.entries.first(where: { $0.id == entryID }),
        let url = ActivityPresentation.links(in: entry.text).first
      else { return }
      openLink(url, from: id)
    }
  }

  func open(_ resource: SessionResource, from id: SessionID) {
    notice = nil
    switch resource.target {
    case .web(let url):
      openLink(url, from: id)
    case .branch(let repositoryPath, let url):
      if let url {
        openLink(url, from: id)
      } else {
        revealFolder(repositoryPath)
      }
    case .folder(let path):
      revealFolder(path)
    }
  }

  /// A click on a link, or its row activated: where Settings say, ⌥ doing the other.
  func openLink(_ url: URL, from id: SessionID) {
    openLink(url, from: id, gesture: .click(alternate: isOptionKeyDown()))
  }

  func openLink(_ url: URL, from id: SessionID, gesture: LinkGesture) {
    guard Self.isWeb(url) else { return }
    guard let route else { return openInBrowser(url) }
    route(url, gesture, id)
  }

  /// The actions of a link's menu, the same as everywhere else (#186).
  func linkActions(for url: URL, in id: SessionID) -> [LinkMenuAction] {
    guard Self.isWeb(url) else { return [.copy] }
    return LinkMenuAction.actions(for: url, hasWebView: hasWebView?(id) ?? false)
  }

  func perform(_ action: LinkMenuAction, on url: URL, from id: SessionID) {
    if let gesture = action.gesture {
      openLink(url, from: id, gesture: gesture)
    } else {
      copy(url.absoluteString)
    }
  }

  /// In the default browser, whatever the session has.
  func openInBrowser(_ url: URL) {
    guard Self.isWeb(url) else { return }
    Task { [opener] in _ = await opener.open(url, with: .defaultApplication) }
  }

  /// Only the web: a link of the summary is written by a model, and must not open anything else.
  private static func isWeb(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https"
  }

  /// The folder, or the closest one that still exists — and then it is said.
  func revealFolder(_ path: String) {
    var url = URL(fileURLWithPath: path, isDirectory: true)
    let wanted = url
    while !opener.exists(url), url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
    }
    if url != wanted {
      notice = String(
        localized:
          "\((wanted.path as NSString).lastPathComponent) no longer exists; its closest folder was revealed.",
        bundle: .module, comment: "A folder's name.")
    }
    opener.reveal(url)
  }

  func openInEditor(_ path: String) {
    notice = nil
    guard let editor, opener.exists(URL(fileURLWithPath: path)) else {
      revealFolder(path)
      return
    }
    Task { [opener] in _ = await opener.open(URL(fileURLWithPath: path), with: editor) }
  }

  var editorName: String? {
    editor.flatMap { opener.name(of: $0) }
  }

  func copy(_ text: String) {
    opener.copy(text)
  }

  /// ⌘C: the URL of a ticket, the name of a branch, the path of a worktree, the text of an entry.
  func copy(_ row: ActivityRowID, in id: SessionID) {
    switch row {
    case .resource(let key):
      guard let resource = journals.value(for: id)?.resources.first(where: { $0.key == key }) else {
        return
      }
      copy(ActivityPresentation.copyText(resource))
    case .entry(let entryID):
      guard let entry = journals.value(for: id)?.entries.first(where: { $0.id == entryID }) else {
        return
      }
      copy(entry.text)
    }
  }
}
