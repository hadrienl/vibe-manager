import Foundation
import VibeDomain

/// Coordinators and their children in the sidebar (#352): each child right under its coordinator,
/// in the coordinator's column and group, whatever its own task status or folder.
///
/// A child's own status is on its row; it is not listed a second time in its own column. A child
/// whose coordinator is archived or gone is an ordinary session again, in its own column.
public enum SessionHierarchy {
  /// The coordinator a session is listed under, when it is listed under one.
  public static func parent(
    of session: WorkSession, in sessions: [SessionID: WorkSession]
  ) -> WorkSession? {
    guard session.status != .archived, let id = session.coordination?.coordinatorID,
      let parent = sessions[id], parent.status != .archived,
      parent.coordination?.isCoordinator == true
    else { return nil }
    return parent
  }

  /// The column a session is shown in: its coordinator's, for a child listed under one.
  public static func column(
    of session: WorkSession, in sessions: [SessionID: WorkSession]
  ) -> SessionTaskStatus {
    parent(of: session, in: sessions)?.taskStatus ?? session.taskStatus
  }

  public static func index(_ sessions: [WorkSession]) -> [SessionID: WorkSession] {
    Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
  }

  /// What a column lists: the sessions the filter keeps, each coordinator followed by its
  /// children. A search that finds a child shows its coordinator with it; a folded coordinator
  /// hides its children, unless a search is under way.
  public static func apply(
    _ filter: SessionFilter,
    to sessions: [WorkSession],
    notes: [SessionID: String] = [:],
    collapsed: Set<SessionID> = []
  ) -> [WorkSession] {
    let byID = index(sessions)
    var children: [SessionID: [WorkSession]] = [:]
    var roots: [WorkSession] = []
    for session in sessions {
      if let parent = parent(of: session, in: byID) {
        children[parent.id, default: []].append(session)
      } else {
        roots.append(session)
      }
    }
    let isNarrowing = filter.isNarrowing
    var result: [WorkSession] = []
    let listed = roots.filter { root in
      guard root.taskStatus == filter.column else { return false }
      if filter.matchesNarrowing(root, notes: notes[root.id]) { return true }
      return (children[root.id] ?? []).contains {
        filter.matchesNarrowing($0, notes: notes[$0.id])
      }
    }
    .sorted(by: filter.ordering)
    for root in listed {
      result.append(root)
      guard let own = children[root.id], !own.isEmpty else { continue }
      let isSearching = !filter.trimmedSearchText.isEmpty
      guard isSearching || !collapsed.contains(root.id) else { continue }
      // The coordinator found for itself shows all its children; found through some, those.
      let rootMatches = filter.matchesNarrowing(root, notes: notes[root.id])
      let shown =
        isNarrowing && !rootMatches
        ? own.filter { filter.matchesNarrowing($0, notes: notes[$0.id]) } : own
      result.append(contentsOf: shown.sorted(by: filter.ordering))
    }
    return result
  }
}
