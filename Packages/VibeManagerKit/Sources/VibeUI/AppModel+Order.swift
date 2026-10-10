import Foundation
import VibeApplication
import VibeDomain

/// The order the user arranges by hand (#44, ADR 0027).
///
/// Sessions are moved inside the column on screen, and inside their group when the sidebar is
/// grouped; a group is moved among the groups of the column. Only in the Manual sort and with
/// nothing narrowing the list: what is moved is then exactly the order that is stored.
extension AppModel {
  /// Whether the sidebar can be rearranged: the Manual sort, no search, no facet.
  public var canReorder: Bool {
    let filter = filter
    return filter.sort == .manual && !filter.isNarrowing
  }

  /// Why the sidebar cannot be rearranged, for the help tag of the commands that would.
  public var reorderUnavailableReason: LocalizedStringResource? {
    let filter = filter
    if filter.sort != .manual {
      return LocalizedStringResource(
        "Choose Sort By › Manual to reorder the sessions.", bundle: .module)
    }
    if filter.isNarrowing {
      return LocalizedStringResource("Clear the filter to reorder the sessions.", bundle: .module)
    }
    return nil
  }

  // MARK: - Sessions

  /// The rows a session is moved among: its group when the sidebar is grouped, its column
  /// otherwise. A folded group's sessions are counted: the order is the group's, not the screen's.
  ///
  /// A coordinator moves among the sessions that are not children, its children with it; a child
  /// moves among its siblings only, never out of its coordinator (#352).
  func reorderingSubset(of id: SessionID) -> [WorkSession]? {
    let rows: [WorkSession]?
    switch sidebarContent {
    case .flat(let sessions):
      rows = sessions.contains(where: { $0.id == id }) ? sessions : nil
    case .grouped(let groups):
      rows = groups.first { $0.sessions.contains { $0.id == id } }?.sessions
    }
    guard let rows, let session = rows.first(where: { $0.id == id }) else { return nil }
    let byID = SessionHierarchy.index(sessions)
    let parent = SessionHierarchy.parent(of: session, in: byID)?.id
    return rows.filter { SessionHierarchy.parent(of: $0, in: byID)?.id == parent }
  }

  /// Whether Move Up (-1) or Move Down (+1) has somewhere to go. At the top of a group there is
  /// nothing above: a session never leaves its folder's group.
  public func canMove(_ id: SessionID, by offset: Int) -> Bool {
    guard canReorder, let subset = reorderingSubset(of: id),
      let index = subset.firstIndex(where: { $0.id == id })
    else { return false }
    return subset.indices.contains(index + offset)
  }

  /// ⌃⌘↑ and ⌃⌘↓, the row's menu and its VoiceOver actions.
  public func move(_ id: SessionID, by offset: Int) async {
    guard canMove(id, by: offset), let subset = reorderingSubset(of: id),
      let index = subset.firstIndex(where: { $0.id == id })
    else { return }
    await move(id, toIndex: index + offset)
  }

  /// A drop in the list. `index` counts the rows of the session's column, or of its group, without
  /// the session itself.
  public func move(_ id: SessionID, toIndex index: Int) async {
    guard canReorder, let subset = reorderingSubset(of: id),
      let reordered = SessionOrder.moving(id, to: index, in: subset)
    else { return }
    await commitOrder(reordered)
    announcePosition(of: id, in: reordered)
  }

  private func announcePosition(of id: SessionID, in reordered: [WorkSession]) {
    guard let index = reordered.firstIndex(where: { $0.id == id }) else { return }
    Announcer.announce(
      String(
        localized: "\(reordered[index].name), position \(index + 1) of \(reordered.count)",
        bundle: .module, comment: "Said after a session is moved: its name, where it is now."))
  }

  // MARK: - Groups

  /// The groups that can be moved, in order: every group but the one of the sessions with no
  /// folder, which stays last.
  private var movableGroups: [SessionGroup] {
    groups.filter { $0.id != nil }
  }

  public func canMoveGroup(_ group: SessionGroup, by offset: Int) -> Bool {
    guard canReorder, group.id != nil,
      let index = movableGroups.firstIndex(where: { $0.id == group.id })
    else { return false }
    return movableGroups.indices.contains(index + offset)
  }

  public func moveGroup(_ group: SessionGroup, by offset: Int) async {
    guard canMoveGroup(group, by: offset),
      let index = movableGroups.firstIndex(where: { $0.id == group.id })
    else { return }
    await moveGroup(group, toIndex: index + offset)
  }

  /// A header dropped among the others. `index` counts the groups without the one moved. Its
  /// sessions come together there, the rest of the column keeping its order.
  public func moveGroup(_ group: SessionGroup, toIndex index: Int) async {
    guard canReorder, let folder = group.id,
      let reordered = SessionOrder.movingGroup(folder, to: index, in: groups)
    else { return }
    await commitOrder(reordered)
    let position = min(max(index, 0), movableGroups.count - 1)
    Announcer.announce(
      String(
        localized: "\(group.title), group \(position + 1) of \(movableGroups.count)",
        bundle: .module, comment: "Said after a group is moved: its name, where it is now."))
  }

  /// The group of the selected session, for Move Group Up and Move Group Down in the View menu.
  public func canMoveSelectedGroup(by offset: Int) -> Bool {
    selectedGroup.map { canMoveGroup($0, by: offset) } ?? false
  }

  public func moveSelectedGroup(by offset: Int) async {
    guard let group = selectedGroup else { return }
    await moveGroup(group, by: offset)
  }

  /// Move Up and Move Down in the Session menu, on the selected session.
  public func canMoveSelection(by offset: Int) -> Bool {
    guard isSessionOnScreen else { return false }
    return selectedSessionID.map { canMove($0, by: offset) } ?? false
  }

  public func moveSelection(by offset: Int) async {
    guard let selectedSessionID else { return }
    await move(selectedSessionID, by: offset)
  }
}
