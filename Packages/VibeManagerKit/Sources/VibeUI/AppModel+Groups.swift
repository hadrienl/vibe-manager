import Foundation
import VibeApplication
import VibeDomain

/// The sidebar grouped by working folder (#27, ADR 0025).
///
/// A group is never stored: it is what `SessionGrouping` makes of the sessions listed. Only what
/// the user wrote (a name) or arranged (the mode, the folds) is kept, under the folder's path.
extension AppModel {
  public var sidebarMode: SidebarMode {
    layout.sidebarMode
  }

  /// The sidebar as it is drawn: the same sessions as `visibleSessions`, in the same order, cut
  /// into groups when the user asked for them.
  public var sidebarContent: SidebarContent {
    let visible = visibleSessions
    guard sidebarMode == .byFolder else { return .flat(visible) }
    return SessionGrouping.content(
      of: visible,
      key: { self.folderKey(for: $0) },
      customNames: folderLabels,
      missingFolders: folderResolution.missing)
  }

  /// The rows on screen, in the order they are drawn: a folded group's sessions are not among
  /// them. What ⌥⌘↑/↓ walks and what ⌘1…⌘9 number.
  public var displayedSessions: [WorkSession] {
    switch sidebarContent {
    case .flat(let sessions):
      return sessions
    case .grouped(let groups, let archived):
      return groups.flatMap { isExpanded($0) ? $0.sessions : [] }
        + (isArchivedSectionExpanded ? archived : [])
    }
  }

  /// The rows in the order they are drawn, folded or not.
  var orderedSessions: [WorkSession] {
    switch sidebarContent {
    case .flat(let sessions):
      return sessions
    case .grouped(let groups, let archived):
      return groups.flatMap(\.sessions) + archived
    }
  }

  /// The folder a session is filed under: where the disk says it is once it has been asked, its
  /// path as written until then.
  public func folderKey(for session: WorkSession) -> SessionFolderKey? {
    guard let path = SessionFolderKey.primaryPath(of: session) else { return nil }
    return folderResolution.keys[path] ?? .lexical(path)
  }

  /// A search unfolds everything, without touching what is stored: looking for a session a fold
  /// hides would be a trap.
  private var isSearching: Bool {
    !filter.trimmedSearchText.isEmpty
  }

  public func isExpanded(_ group: SessionGroup) -> Bool {
    isSearching || !layout.collapsedFolders.contains(group.foldKey)
  }

  public var isArchivedSectionExpanded: Bool {
    isSearching || layout.isArchivedSectionExpanded
  }

  // MARK: - Commands

  /// The selection stays where it is: grouping changes how the list is drawn, not where the user is.
  public func setSidebarMode(_ mode: SidebarMode) {
    layout.setSidebarMode(mode)
    if let selectedSessionID, mode == .byFolder { reveal(selectedSessionID) }
  }

  public func toggleGrouping() {
    setSidebarMode(sidebarMode == .byFolder ? .flat : .byFolder)
  }

  /// Folding the group of the selected session keeps the selection, and its terminal on screen.
  public func setExpanded(_ isExpanded: Bool, group: SessionGroup) {
    layout.setCollapsed(!isExpanded, folders: [group.foldKey])
  }

  public func setArchivedSectionExpanded(_ isExpanded: Bool) {
    layout.setArchivedSectionExpanded(isExpanded)
  }

  /// The group of the selected session, in the grouped view.
  public var selectedGroup: SessionGroup? {
    guard case .grouped(let groups, _) = sidebarContent, let selectedSessionID else { return nil }
    return groups.first { group in group.sessions.contains { $0.id == selectedSessionID } }
  }

  public func collapseSelectedGroup() {
    guard let group = selectedGroup else { return }
    setExpanded(false, group: group)
  }

  public func expandSelectedGroup() {
    guard let group = selectedGroup else { return }
    setExpanded(true, group: group)
  }

  public var groups: [SessionGroup] {
    guard case .grouped(let groups, _) = sidebarContent else { return [] }
    return groups
  }

  public func setAllGroupsExpanded(_ isExpanded: Bool) {
    layout.setCollapsed(!isExpanded, folders: Set(groups.map(\.foldKey)))
  }

  /// Unfolds whatever hides a session.
  func reveal(_ id: SessionID) {
    guard sidebarMode == .byFolder,
      let session = sessions.first(where: { $0.id == id })
    else { return }
    if session.status == .archived {
      if !layout.isArchivedSectionExpanded { layout.setArchivedSectionExpanded(true) }
      return
    }
    let key = folderKey(for: session) ?? .unfiled
    if layout.collapsedFolders.contains(key) {
      layout.setCollapsed(false, folders: [key])
    }
  }

  /// Names a group, or gives it back its folder's name with an empty one. Neither the folder nor
  /// the sessions change: the name lives apart, under the folder's path.
  public func rename(_ group: SessionGroup, to name: String) async {
    guard let folder = group.id else { return }
    do {
      folderLabels = try await folderLabelStore.setLabel(FolderLabel.normalized(name), for: folder)
    } catch {
      folderLabelFailure =
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  public func dismissFolderLabelFailure() {
    folderLabelFailure = nil
  }

  // MARK: - Status

  /// What a session's row says, and what its group's header folds together.
  public func status(of session: WorkSession) -> SessionStatusPresentation {
    if isRestoring(session.id) { return .restoring }
    let pane = pane(for: session.id)
    return SessionStatusPresentation.make(
      session: session,
      paneStatus: pane?.status,
      resolution: resolution(forID: session.id),
      wasStoppedOnPurpose: pane?.wasStoppedOnPurpose == true,
      activity: activity(for: session.id))
  }

  public func summary(of group: SessionGroup) -> SessionGroupSummary {
    SessionGroupStatus.aggregate(group.sessions.map(status(of:)))
  }

  // MARK: - Loading

  func loadFolderLabels() async {
    do {
      folderLabels = try await folderLabelStore.labels()
    } catch {
      // The groups show their folders' names. Renaming says why it cannot be written, and the
      // unreadable document is left as it is.
      diagnostics.record(.store, .error, "folders.unreadable")
    }
  }

  /// Asks the disk where each working folder is, away from the main thread. Until it answers,
  /// the groups are filed under the paths as written, which is right for almost every folder.
  func resolveFolders() {
    let paths = Set(sessions.compactMap(SessionFolderKey.primaryPath(of:)))
    folderResolutionTask?.cancel()
    folderResolutionTask = Task { [weak self] in
      let resolution = await SessionFolderResolution.resolve(paths)
      guard !Task.isCancelled, let self, resolution != self.folderResolution else { return }
      self.folderResolution = resolution
    }
  }
}

extension SessionFolderKey {
  /// What the group of the sessions without a folder is folded under.
  public static let unfiled = SessionFolderKey(path: "")
}

extension SessionGroup {
  /// What this group's fold is stored under.
  public var foldKey: SessionFolderKey { id ?? .unfiled }
}
