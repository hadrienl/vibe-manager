import Foundation
import VibeDomain

/// The order the user arranges the sessions in by hand (#44, ADR 0027).
///
/// There is one order, kept in the sessions' ranks. A column and a group are subsequences of it,
/// which is what keeps the flat list and the grouped one telling the same story. A move never
/// inserts a session into that global order: it hands the ranks a subset already held back to
/// the same subset, in its new order. Nothing outside the subset changes place, and a group keeps
/// the smallest rank it had, so moving a session inside a group never moves the group.
public enum SessionOrder {
  /// Every session from the top: rank, then identifier, so that two equal ranks — a store edited
  /// by hand — still come back in the same order.
  public static func ordered(_ sessions: [WorkSession]) -> [WorkSession] {
    sessions.sorted {
      $0.rank != $1.rank ? $0.rank < $1.rank : $0.id.description < $1.id.description
    }
  }

  /// The ranks `reordered` already held, handed back to it in its new order. Only the sessions
  /// whose rank changes are returned.
  ///
  /// Two sessions of the subset with the same rank would keep sharing it, and their order would
  /// be left to their identifiers: the ranks are spread apart first, above the smallest one, so
  /// the order asked for is the order stored.
  public static func redistribute(_ reordered: [WorkSession]) -> [SessionID: Int] {
    var slots = reordered.map(\.rank).sorted()
    for index in slots.indices.dropFirst() where slots[index] <= slots[index - 1] {
      slots[index] = slots[index - 1] + 1
    }
    var ranks: [SessionID: Int] = [:]
    for (session, rank) in zip(reordered, slots) where session.rank != rank {
      ranks[session.id] = rank
    }
    return ranks
  }

  /// `subset` with `moved` taken out and put back at `index`, counted in the subset without it:
  /// a session moved in its column, or in its group. `nil` when the session is not in the subset
  /// or does not move.
  public static func moving(
    _ moved: SessionID, to index: Int, in subset: [WorkSession]
  ) -> [WorkSession]? {
    guard let from = subset.firstIndex(where: { $0.id == moved }) else { return nil }
    var reordered = subset
    let session = reordered.remove(at: from)
    let destination = min(max(index, 0), reordered.count)
    guard destination != from else { return nil }
    reordered.insert(session, at: destination)
    return reordered
  }

  /// The sessions of a grouped column once the group `folder` is put at `index` among the groups,
  /// counted without it. Its sessions come together there, one after the other; the sessions with
  /// no folder stay last, where the grouping always draws them, and are never moved.
  ///
  /// `nil` when the group is not there, is the one with no folder, or does not move.
  public static func movingGroup(
    _ folder: SessionFolderKey, to index: Int, in groups: [SessionGroup]
  ) -> [WorkSession]? {
    let filed = groups.filter { $0.id != nil }
    guard let from = filed.firstIndex(where: { $0.id == folder }) else { return nil }
    var reordered = filed
    let group = reordered.remove(at: from)
    let destination = min(max(index, 0), reordered.count)
    guard destination != from else { return nil }
    reordered.insert(group, at: destination)
    let unfiled = groups.filter { $0.id == nil }
    return (reordered + unfiled).flatMap(\.sessions)
  }
}

/// Writes the order the user arranged. The ranks are the only thing it touches: the last
/// activity of a session is not moved by moving the session.
public struct ReorderSessions: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  /// - Parameter reordered: a column or a group, in its new order.
  /// - Returns: the sessions whose rank changed.
  @discardableResult
  public func callAsFunction(_ reordered: [WorkSession]) async throws -> Int {
    let ranks = SessionOrder.redistribute(reordered)
    guard !ranks.isEmpty else { return 0 }
    try await repository.reorder(ranks)
    return ranks.count
  }
}
