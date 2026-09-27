import Foundation
import VibeDomain

/// The sessions the sidebar has selected, and the one of them on screen (#77).
///
/// The main area and the inspector always show one session: `displayed`, the last one clicked.
/// The others only say what the next command applies to. A selection of one is the ordinary case,
/// and every way of going to a session — a plain click, ⌘1…9, the palette, a notification — comes
/// back to it.
///
/// The list reports a set, not a click, so the click is read from what changed: the row a ⌘-click
/// added, or the far end of the range a ⇧-click drew from the row on screen.
public struct SessionSelection: Equatable, Sendable {
  public private(set) var displayed: SessionID?
  /// In the order they were added, `displayed` among them.
  public private(set) var members: [SessionID]

  public init(displayed: SessionID? = nil) {
    self.displayed = displayed
    members = displayed.map { [$0] } ?? []
  }

  public var ids: Set<SessionID> { Set(members) }
  public var isMultiple: Bool { members.count > 1 }

  public func contains(_ id: SessionID) -> Bool {
    members.contains(id)
  }

  /// What the list answered to a click, a ⇧-click, a ⌘-click or ⌘A.
  ///
  /// - Parameter displayOrder: the rows as the sidebar draws them, to tell the far end of a range.
  public mutating func applyList(_ ids: Set<SessionID>, displayOrder: [SessionID]) {
    guard ids.count > 1 else {
      collapse(to: ids.first)
      return
    }
    let previous = Set(members)
    let added = ids.subtracting(previous)
    let position = Dictionary(
      displayOrder.enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    // The rows added, in the order they are drawn; one the sidebar does not draw goes last.
    let addedInOrder = added.sorted {
      (position[$0] ?? .max, $0.rawValue.uuidString) < (
        position[$1] ?? .max, $1.rawValue.uuidString
      )
    }
    var kept = members.filter { ids.contains($0) } + addedInOrder

    let shown: SessionID?
    if added.count == 1 {
      // A ⌘-click, even one that leaves no row unselected.
      shown = addedInOrder.first
    } else if let displayed, ids.contains(displayed), ids == Set(displayOrder) || added.isEmpty {
      // ⌘A, or a row taken out of the selection: what is on screen stays.
      shown = displayed
    } else if !added.isEmpty {
      // A range: its far end from the row the user started from is the row they clicked.
      let anchor = displayed.flatMap { position[$0] } ?? 0
      shown = addedInOrder.max { distance(position[$0], anchor) < distance(position[$1], anchor) }
    } else {
      // The row on screen was taken out: by a ⌘-click, or by a ⇧-click that shrank the range
      // toward its anchor. Either way the nearest row still selected takes its place — for a
      // shrunk range, the row clicked. Between two as near, the one added last.
      let origin = displayed.flatMap { position[$0] }
      // A row the sidebar does not draw is never the nearest.
      let nearness = { (id: SessionID) in
        origin.flatMap { origin in position[id].map { abs($0 - origin) } } ?? .max
      }
      shown = kept.reversed().min { nearness($0) < nearness($1) }
    }
    if let shown, let index = kept.firstIndex(of: shown) {
      kept.remove(at: index)
      kept.append(shown)
    }
    members = kept
    displayed = shown
  }

  /// Every row the sidebar draws, around the session on screen.
  public mutating func selectAll(displayOrder: [SessionID]) {
    guard !displayOrder.isEmpty else { return }
    let others = displayOrder.filter { $0 != displayed }
    members = others + (displayed.map { [$0] } ?? [])
    if displayed == nil { displayed = members.last }
  }

  /// Back to one session: a plain click, Escape, a shortcut that goes to a session.
  public mutating func collapse(to id: SessionID?) {
    displayed = id
    members = id.map { [$0] } ?? []
  }

  /// Shows a session without undoing the selection it belongs to. Outside it, the selection
  /// becomes that session alone.
  public mutating func show(_ id: SessionID?) {
    guard let id, members.contains(id) else {
      collapse(to: id)
      return
    }
    displayed = id
  }

  /// Keeps only the rows still drawn: a selection never holds a session the user cannot see. The
  /// session on screen is not the selection's to drop — a search can hide it and leave it there.
  public mutating func prune(keeping visible: Set<SessionID>) {
    members = members.filter { visible.contains($0) || $0 == displayed }
  }

  private func distance(_ position: Int?, _ anchor: Int) -> Int {
    guard let position else { return -1 }
    return abs(position - anchor)
  }
}
