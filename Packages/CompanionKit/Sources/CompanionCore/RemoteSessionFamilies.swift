import Foundation

/// The line that ties a coordinator to the rows under it, as the Mac's sidebar draws it (#468).
public enum RemoteFamilyLine: Equatable, Sendable {
  /// A coordinator with rows under it: the line leaves from under its badge.
  case parent
  /// A row of the family, reached by an elbow. The last one ends the line.
  case child(isLast: Bool)
}

/// A row of a column of the phone's list.
public struct RemoteSessionRow: Identifiable, Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    /// `ownStatus` is said when a child is listed in a column that is not its own.
    case session(RemoteSession, ownStatus: RemoteTaskStatus?)
    /// What shows or hides a coordinator's done children.
    case doneChildren(coordinatorID: String, count: Int, isShown: Bool)
  }

  public let content: Content
  public let line: RemoteFamilyLine?
  /// How many children a folded coordinator keeps out of the list.
  public var foldedChildren = 0

  public var id: String {
    switch content {
    case .session(let session, _): session.id
    case .doneChildren(let coordinatorID, _, _): "done-" + coordinatorID
    }
  }

  /// Set in under its coordinator.
  public var isChild: Bool {
    if case .child = line { return true }
    return false
  }
}

/// A column's rows of one folder.
public struct RemoteSessionGroup: Equatable, Sendable {
  public let path: String
  public let name: String
  public let rows: [RemoteSessionRow]
}

/// The Mac's rules for coordinators and their children (`SessionHierarchy`, #352), on what the
/// phone receives: each child right under its coordinator, in the coordinator's column and folder,
/// whatever its own status; its done ones behind a row until asked for.
public struct RemoteSessionFamilies: Sendable {
  private let byID: [String: RemoteSession]
  private let listed: [RemoteSession]

  public init(_ sessions: [RemoteSession]) {
    byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
    listed = sessions
  }

  /// The coordinator a session is listed under. An archived session is listed under none, as on
  /// the Mac (`CoordinationPolicy`); nor is one under an archived coordinator, or under one listed
  /// under another itself: the session would show in no column.
  private func parent(of session: RemoteSession) -> RemoteSession? {
    guard let parent = listedCoordinator(of: session), listedCoordinator(of: parent) == nil else {
      return nil
    }
    return parent
  }

  private func listedCoordinator(of session: RemoteSession) -> RemoteSession? {
    guard session.status != .archived, let id = session.coordinatorID, let parent = byID[id],
      parent.status != .archived
    else { return nil }
    return parent
  }

  private func isListed(_ session: RemoteSession, in column: RemoteTaskStatus) -> Bool {
    (parent(of: session)?.status ?? session.status) == column
  }

  /// How many sessions a column lists, its done children included.
  public func count(in column: RemoteTaskStatus) -> Int {
    listed.filter { isListed($0, in: column) }.count
  }

  /// The column by folder, `showingDone` naming the coordinators whose done children show, and
  /// `folded` those whose children are all put away.
  public func groups(
    in column: RemoteTaskStatus, showingDone: Set<String>, folded: Set<String> = []
  ) -> [RemoteSessionGroup] {
    let byRank: (RemoteSession, RemoteSession) -> Bool = {
      ($0.rank, $0.updatedAt) < ($1.rank, $1.updatedAt)
    }
    let shown = listed.filter { isListed($0, in: column) }
    let children = Dictionary(
      grouping: shown.filter { parent(of: $0) != nil }, by: { parent(of: $0)?.id ?? "" })
    let folders = Dictionary(grouping: shown.filter { parent(of: $0) == nil }, by: \.folderPath)
    return folders.keys.sorted {
      (folders[$0]?.first?.folderName ?? "").localizedStandardCompare(
        folders[$1]?.first?.folderName ?? "") == .orderedAscending
    }.map { path in
      let tops = (folders[path] ?? []).sorted(by: byRank)
      let rows = tops.flatMap { top in
        family(
          of: top, children: (children[top.id] ?? []).sorted(by: byRank), column: column,
          showingDone: showingDone, isFolded: folded.contains(top.id))
      }
      return RemoteSessionGroup(path: path, name: tops.first?.folderName ?? path, rows: rows)
    }
  }

  private func family(
    of top: RemoteSession, children: [RemoteSession], column: RemoteTaskStatus,
    showingDone: Set<String>, isFolded: Bool
  ) -> [RemoteSessionRow] {
    if isFolded, !children.isEmpty {
      return [
        RemoteSessionRow(
          content: .session(top, ownStatus: nil), line: nil, foldedChildren: children.count)
      ]
    }
    let doneCount = children.filter { $0.status == .done }.count
    let isShown = showingDone.contains(top.id)
    var under: [RemoteSessionRow.Content] =
      children
      .filter { $0.status != .done || isShown }
      .map { .session($0, ownStatus: $0.status == column ? nil : $0.status) }
    if doneCount > 0 {
      under.append(.doneChildren(coordinatorID: top.id, count: doneCount, isShown: isShown))
    }
    let head = RemoteSessionRow(
      content: .session(top, ownStatus: nil), line: under.isEmpty ? nil : .parent)
    return [head]
      + under.enumerated().map { index, content in
        RemoteSessionRow(content: content, line: .child(isLast: index == under.count - 1))
      }
  }
}
