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

  private(set) var journals: [SessionID: SessionJournal] = [:]
  private(set) var summarizing: Set<SessionID> = []
  /// Sessions whose journal was asked of the store, found or not.
  private(set) var looked: Set<SessionID> = []
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
  /// The editor chosen in the settings, for Open in Editor.
  @ObservationIgnored var editor: EditorChoice?

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
        self.journals[update.sessionID] = update.journal
        self.looked.insert(update.sessionID)
        if update.isSummarizing {
          self.summarizing.insert(update.sessionID)
        } else {
          self.summarizing.remove(update.sessionID)
        }
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
      guard let self, let journal, self.journals[id] == nil else { return }
      self.journals[id] = journal
    }
  }

  func retry(_ id: SessionID) {
    Task { [monitor] in await monitor.retry(id) }
  }

  func journal(for id: SessionID) -> SessionJournal? {
    journals[id]
  }

  func isSummarizing(_ id: SessionID) -> Bool {
    summarizing.contains(id)
  }

  // MARK: - Screen state

  func requestFocus() {
    focusRequest += 1
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
      guard let resource = journals[id]?.resources.first(where: { $0.key == key }) else { return }
      open(resource)
    case .entry(let entryID):
      guard let entry = journals[id]?.entries.first(where: { $0.id == entryID }),
        let url = ActivityPresentation.links(in: entry.text).first
      else { return }
      openLink(url)
    }
  }

  func open(_ resource: SessionResource) {
    notice = nil
    switch resource.target {
    case .web(let url):
      openLink(url)
    case .branch(let repositoryPath, let url):
      if let url {
        openLink(url)
      } else {
        revealFolder(repositoryPath)
      }
    case .folder(let path):
      revealFolder(path)
    }
  }

  /// Only the web: a link of the summary is written by a model, and must not open anything else.
  func openLink(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return
    }
    Task { [opener] in _ = await opener.open(url, with: .defaultApplication) }
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
      guard let resource = journals[id]?.resources.first(where: { $0.key == key }) else { return }
      copy(ActivityPresentation.copyText(resource))
    case .entry(let entryID):
      guard let entry = journals[id]?.entries.first(where: { $0.id == entryID }) else { return }
      copy(entry.text)
    }
  }
}
