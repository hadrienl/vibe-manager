import Foundation
import Observation
import VibeApplication
import VibeDomain

/// What an unfolded untracked folder shows.
enum DirectoryListingState: Equatable, Sendable {
  case loading
  case loaded(UntrackedListing)
  case failed(String)
}

/// The screen state of the inspector's Git pane: what is unfolded, how much of each list is shown,
/// what is selected, and what the unfolded untracked folders hold.
///
/// Kept per session for the length of the run, and never persisted: coming back to a session finds
/// it as it was left, a relaunch starts from the defaults. What the user folded or unfolded wins
/// over the default, so a repository folded by hand stays folded while its agent keeps writing.
@MainActor
@Observable
final class GitInspectorModel {
  /// How many rows a section shows before "Show More".
  static let pageSize = 200
  /// An untracked or committed list longer than this starts folded: a folder `.gitignore` forgot,
  /// or a branch that carries a long history.
  static let foldedUntrackedThreshold = 50

  private struct SessionState {
    var repositories: [String: Bool] = [:]
    var sections: [GitSectionID: Bool] = [:]
    var rowLimits: [GitSectionID: Int] = [:]
    var directories: Set<GitInspectorRowID> = []
  }

  /// A folder's listing, of one session.
  private struct ListingKey: Hashable {
    let session: SessionID
    let row: GitInspectorRowID
  }

  typealias ListUntracked =
    @Sendable (String, RepositoryStatusKey) async -> Result<UntrackedListing, RepositoryStatusIssue>

  /// Folding and "Show More". Kept apart from the selection and the listings, each observed on
  /// its own: an arrow key moving the selection must not invalidate every list of every group.
  private var sessions: [SessionID: SessionState] = [:]
  private var selections: [SessionID: GitInspectorRowID] = [:]
  private var listings: [ListingKey: DirectoryListingState] = [:]
  /// The editor chosen in the settings, mirrored here so that the menus follow a change made there.
  var editor: EditorChoice?
  /// Said under the pane's header after a gesture that could not do all it was asked, until the
  /// next gesture.
  private(set) var notice: String?

  private let listUntracked: ListUntracked?
  private let opener: any FileOpening

  /// Presentations kept while their inputs do not change: a selection moving must not rebuild
  /// five thousand rows.
  @ObservationIgnored private var presentations:
    [String: (
      report: RepositoryBranchReport, state: RepositoryStatusState?, names: [SessionID: String],
      value: RepositoryGroupPresentation
    )] = [:]
  @ObservationIgnored private var folders:
    (repositories: [String], roots: [String], value: [String])?

  /// Listings being read, those asked for again meanwhile, and the number of the last one asked:
  /// one reading per folder at a time, and never an older answer over a newer one.
  @ObservationIgnored private var listingsInFlight: Set<ListingKey> = []
  @ObservationIgnored private var listingsPending: Set<ListingKey> = []

  init(
    listUntracked: ListUntracked? = nil,
    opener: any FileOpening,
    editor: EditorChoice? = nil
  ) {
    self.listUntracked = listUntracked
    self.opener = opener
    self.editor = editor
  }

  // MARK: - Presentation

  func group(
    for report: RepositoryBranchReport, state: RepositoryStatusState?,
    sessionNames: [SessionID: String]
  ) -> RepositoryGroupPresentation {
    if let cached = presentations[report.path], cached.report == report, cached.state == state,
      cached.names == sessionNames
    {
      return cached.value
    }
    let value = RepositoryGroupPresentation(
      report: report, state: state, sessionNames: sessionNames)
    presentations[report.path] = (report, state, sessionNames, value)
    return value
  }

  /// The attached folders no repository of the report covers. Resolving a path asks the disk, so
  /// it is done once per report rather than at every redraw.
  func plainFolders(of session: WorkSession, report: SessionBranchReport?) -> [String] {
    guard let report else { return [] }
    let repositories = session.repositories.map(\.path)
    let roots = report.repositories.map(\.path)
    if let folders, folders.repositories == repositories, folders.roots == roots {
      return folders.value
    }
    let value = GitPanePresentation.plainFolders(repositories, roots: roots)
    folders = (repositories, roots, value)
    return value
  }

  // MARK: - Expansion

  func isExpanded(_ group: RepositoryGroupPresentation, in session: SessionID) -> Bool {
    sessions[session]?.repositories[group.repositoryPath] ?? group.isExpandedByDefault
  }

  func setExpanded(_ repositoryPath: String, _ isExpanded: Bool, in session: SessionID) {
    sessions[session, default: SessionState()].repositories[repositoryPath] = isExpanded
    // What is folded away cannot stay selected: Return would act on a row nobody sees.
    if !isExpanded, selections[session]?.repositoryPath == repositoryPath {
      selections[session] = nil
    }
  }

  func isExpanded(_ section: FileSection, in session: SessionID) -> Bool {
    isExpanded(section.id, rowCount: section.rows.count, in: session)
  }

  private func isExpanded(_ section: GitSectionID, rowCount: Int, in session: SessionID) -> Bool {
    if let chosen = sessions[session]?.sections[section] { return chosen }
    switch section.column {
    case .untracked, .committed: return rowCount <= Self.foldedUntrackedThreshold
    case .conflicts, .staged, .unstaged: return true
    }
  }

  func setExpanded(_ section: GitSectionID, _ isExpanded: Bool, in session: SessionID) {
    sessions[session, default: SessionState()].sections[section] = isExpanded
    if !isExpanded, selections[session]?.section == section {
      selections[session] = nil
    }
  }

  func rowLimit(_ section: GitSectionID, in session: SessionID) -> Int {
    sessions[session]?.rowLimits[section] ?? Self.pageSize
  }

  func showMore(_ section: GitSectionID, in session: SessionID) {
    sessions[session, default: SessionState()].rowLimits[section] =
      rowLimit(section, in: session) + Self.pageSize
  }

  func showAll(_ section: GitSectionID, in session: SessionID) {
    sessions[session, default: SessionState()].rowLimits[section] = .max
  }

  // MARK: - Untracked folders

  func isExpanded(directory row: GitInspectorRowID, in session: SessionID) -> Bool {
    sessions[session]?.directories.contains(row) == true
  }

  func listing(of row: GitInspectorRowID, in session: SessionID) -> DirectoryListingState? {
    listings[ListingKey(session: session, row: row)]
  }

  /// Unfolds an untracked folder and reads what it holds. Nothing is read while it is folded.
  func setExpanded(directory row: GitInspectorRowID, _ isExpanded: Bool, in session: SessionID) {
    let key = ListingKey(session: session, row: row)
    if isExpanded {
      sessions[session, default: SessionState()].directories.insert(row)
      if listings[key] == nil { listings[key] = .loading }
      read(key)
    } else {
      sessions[session]?.directories.remove(row)
      listings[key] = nil
      listingsPending.remove(key)
      if let selected = selections[session], selected.child != nil,
        selected.repositoryPath == row.repositoryPath, selected.path == row.path
      {
        selections[session] = nil
      }
    }
  }

  /// One reading per folder at a time. Whatever asks during it gets one more reading after it,
  /// never a second one beside it: two would hold both of the monitor's slots, and the older
  /// answer could land last.
  private func read(_ key: ListingKey) {
    guard let listUntracked else {
      listings[key] = .failed("Untracked folders cannot be read here.")
      return
    }
    guard !listingsInFlight.contains(key) else {
      listingsPending.insert(key)
      return
    }
    listingsInFlight.insert(key)
    listingsPending.remove(key)
    let repository = RepositoryStatusKey(
      sessionID: key.session, repositoryPath: key.row.repositoryPath)
    Task {
      let result = await listUntracked(key.row.path, repository)
      self.listingsInFlight.remove(key)
      // Folded meanwhile: what was read is not wanted any more.
      guard self.sessions[key.session]?.directories.contains(key.row) == true else {
        self.listingsPending.remove(key)
        return
      }
      if self.listingsPending.contains(key) {
        // The folder moved during the reading: what was read may already be old.
        self.read(key)
        return
      }
      switch result {
      case .success(let listing):
        self.listings[key] = .loaded(listing)
      case .failure(let issue):
        self.listings[key] = .failed(issue.message)
      }
      self.reconcileSelection(in: key.session, repositoryPath: key.row.repositoryPath)
    }
  }

  // MARK: - Selection

  func selection(in session: SessionID) -> GitInspectorRowID? {
    selections[session]
  }

  func select(_ row: GitInspectorRowID?, in session: SessionID) {
    guard selections[session] != row else { return }
    selections[session] = row
  }

  // MARK: - Following the monitor

  /// A repository's state changed: the selection follows its file from one list to another, and
  /// the unfolded folders of that repository are read again — only then, never on a timer.
  func statesChanged(_ states: [RepositoryStatusState]) {
    for state in states {
      let session = state.key.sessionID
      let path = state.key.repositoryPath
      entriesByRepository[state.key] = state.entries
      committedByRepository[state.key] = state.committed
      if let current = sessions[session] {
        let folders = Set(
          state.entries.filter { $0.entry.kind == .untrackedDirectory }.map(\.entry.path))
        for row in current.directories where row.repositoryPath == path {
          let key = ListingKey(session: session, row: row)
          if folders.contains(row.path) {
            if state.phase == .fresh { read(key) }
          } else {
            sessions[session]?.directories.remove(row)
            listings[key] = nil
          }
        }
      }
      reconcileSelection(in: session, repositoryPath: path)
    }
  }

  /// The last entries of each repository, to place a selection against.
  @ObservationIgnored private var entriesByRepository: [RepositoryStatusKey: [AttributedEntry]] =
    [:]
  @ObservationIgnored private var committedByRepository:
    [RepositoryStatusKey: [AttributedCommittedFile]] = [:]

  private func reconcileSelection(in session: SessionID, repositoryPath: String) {
    let key = RepositoryStatusKey(sessionID: session, repositoryPath: repositoryPath)
    guard let selected = selections[session], selected.repositoryPath == repositoryPath,
      let entries = entriesByRepository[key]
    else { return }
    // Only the selected path is looked for: building every row, labels and all, to place one
    // selection would cost more than the publication it follows. Every entry of it counts: Git
    // can list one path twice, a staged deletion beside the untracked file kept on disk.
    let committed = committedByRepository[key] ?? []
    var columns = entries.filter { $0.entry.path == selected.path }
      .flatMap { ChangeColumn.of($0.entry) }
    if committed.contains(where: { $0.file.path == selected.path }) { columns.append(.committed) }
    if let child = selected.child {
      // A file of an unfolded folder: kept while its folder is listed and still holds it.
      let parent = GitInspectorRowID(
        repositoryPath: repositoryPath, column: .untracked, path: selected.path)
      guard columns.contains(.untracked) else {
        selections[session] = nil
        return
      }
      if case .loaded(let listing) = listings[ListingKey(session: session, row: parent)],
        !listing.paths.contains(child)
      {
        selections[session] = nil
      }
      return
    }
    if columns.contains(selected.column) { return }
    // Staged since, unstaged again or committed: the file the user picked, not the list it was in.
    let order: [ChangeColumn] = [.staged, .unstaged, .conflicts, .untracked, .committed]
    guard let column = order.first(where: columns.contains) else {
      selections[session] = nil
      return
    }
    let moved = GitInspectorRowID(
      repositoryPath: repositoryPath, column: column, path: selected.path)
    selections[session] = moved
    // Followed into a list where it lies past what is shown: the list is opened far enough to
    // show it, rather than keeping a selection nobody can see.
    var index: Int?
    var rowCount = 0
    let paths =
      column == .committed
      ? committed.map(\.file.path)
      : entries.filter { ChangeColumn.of($0.entry).contains(column) }.map(\.entry.path)
    for path in paths {
      if index == nil, path == selected.path { index = rowCount }
      rowCount += 1
    }
    if let index, index >= rowLimit(moved.section, in: session) {
      sessions[session, default: SessionState()].rowLimits[moved.section] =
        (index / Self.pageSize + 1) * Self.pageSize
    }
    // Folded by the user, or by default — a long untracked list: opened all the same.
    if !isExpanded(moved.section, rowCount: rowCount, in: session) {
      sessions[session, default: SessionState()].sections[moved.section] = true
    }
  }

  // MARK: - Gestures

  /// Double-click or Return: the editor chosen in the settings, or the Finder. A folder — an
  /// untracked one, a submodule — is revealed: it is a place, not a file to edit.
  func activate(_ row: GitInspectorRowID) async {
    notice = nil
    guard let url = Self.url(of: row) else { return }
    guard !isFolder(row), opener.exists(url), let editor else {
      reveal(row)
      return
    }
    await open(url, with: editor)
  }

  /// "Open with Default Application", whatever editor the settings chose.
  func openWithDefaultApplication(_ row: GitInspectorRowID) async {
    notice = nil
    guard let url = Self.url(of: row), opener.exists(url) else {
      reveal(row)
      return
    }
    await open(url, with: .defaultApplication)
  }

  private func isFolder(_ row: GitInspectorRowID) -> Bool {
    if let child = row.child { return child.hasSuffix("/") }
    if row.path.hasSuffix("/") { return true }
    return entriesByRepository.contains { key, entries in
      key.repositoryPath == row.repositoryPath
        && entries.contains {
          guard $0.entry.path == row.path, case .submodule = $0.entry.kind else { return false }
          return true
        }
    }
  }

  /// A repository's own folder, in the editor.
  func openRepository(_ repositoryPath: String) async {
    notice = nil
    guard let editor else {
      opener.reveal(URL(fileURLWithPath: repositoryPath))
      return
    }
    await open(URL(fileURLWithPath: repositoryPath, isDirectory: true), with: editor)
  }

  private func open(_ url: URL, with editor: EditorChoice) async {
    guard let name = opener.name(of: editor) else {
      opener.reveal(url)
      notice =
        "The editor chosen in Settings is no longer installed. The file was revealed instead."
      return
    }
    if await !opener.open(url, with: editor) {
      opener.reveal(url)
      notice = "\(url.lastPathComponent) could not be opened in \(name). It was revealed instead."
    }
  }

  /// Selects the file in the Finder — or, for one that is gone, the closest folder that is not.
  func reveal(_ row: GitInspectorRowID) {
    guard var url = Self.url(of: row) else { return }
    let root = URL(fileURLWithPath: row.repositoryPath)
    while !opener.exists(url), url.path.count > root.path.count {
      url.deleteLastPathComponent()
    }
    opener.reveal(url)
  }

  func revealRepository(_ repositoryPath: String) {
    opener.reveal(URL(fileURLWithPath: repositoryPath))
  }

  func copyPath(_ row: GitInspectorRowID, relative: Bool) {
    if relative {
      opener.copy(row.relativePath)
    } else if let url = Self.url(of: row) {
      opener.copy(url.path)
    }
  }

  func copy(_ text: String) {
    opener.copy(text)
  }

  var editorName: String? {
    editor.flatMap { opener.name(of: $0) }
  }

  func installedEditors() -> [KnownEditor] {
    opener.installedEditors()
  }

  func name(of editor: EditorChoice) -> String? {
    opener.name(of: editor)
  }

  /// The row's file on disk. The path comes from Git, a process of its own: one that would lead
  /// outside the repository is refused rather than followed.
  static func url(of row: GitInspectorRowID) -> URL? {
    let root = (row.repositoryPath as NSString).standardizingPath
    var relative = row.relativePath
    if relative.hasSuffix("/") { relative.removeLast() }
    guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
    let full = ((root as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    guard full.hasPrefix(root + "/") else { return nil }
    return URL(fileURLWithPath: full)
  }
}
