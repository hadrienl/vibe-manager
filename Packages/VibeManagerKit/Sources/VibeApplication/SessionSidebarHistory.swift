import VibeDomain

/// A session that was archived, and where it stood: what ⌘Z puts back (#242). A batch archive is
/// one entry of several: one ⌘Z brings it all back.
public struct SessionArchiveUndo: Hashable, Sendable {
  public let id: SessionID
  /// The column it left for the archive.
  public let taskStatus: SessionTaskStatus
  /// Whether it was the session on screen: it comes back selected then.
  public let wasSelected: Bool

  public init(id: SessionID, taskStatus: SessionTaskStatus, wasSelected: Bool) {
    self.id = id
    self.taskStatus = taskStatus
    self.wasSelected = wasSelected
  }
}

/// What ⌘Z undoes where the sidebar or the inspector holds the keyboard, last first: a rename, a
/// change of icon (#183), an archive (#242).
public struct SessionSidebarHistory: Hashable, Sendable {
  public enum Entry: Hashable, Sendable {
    case identity(SessionIdentityChange)
    case archive([SessionArchiveUndo])

    /// What is left of the entry once the sessions no longer stored are taken out of it.
    func keeping(only ids: Set<SessionID>) -> Entry? {
      switch self {
      case .identity(let change):
        return ids.contains(change.id) ? self : nil
      case .archive(let archives):
        let kept = archives.filter { ids.contains($0.id) }
        return kept.isEmpty ? nil : .archive(kept)
      }
    }
  }

  public static let limit = 50

  public private(set) var undoStack: [Entry] = []
  /// Only renames and badge changes are done again: an archive undone is not redone, ⌃⌘A does it.
  public private(set) var redoStack: [SessionIdentityChange] = []

  public init() {}

  public var canUndo: Bool { !undoStack.isEmpty }
  public var canRedo: Bool { !redoStack.isEmpty }

  public mutating func record(_ change: SessionIdentityChange) {
    push(.identity(change))
    redoStack.removeAll()
  }

  public mutating func record(_ archives: [SessionArchiveUndo]) {
    guard !archives.isEmpty else { return }
    push(.archive(archives))
    redoStack.removeAll()
  }

  /// The entry to undo, a rename or a badge change already turned around.
  public mutating func popUndo() -> Entry? {
    switch undoStack.popLast() {
    case .identity(let change): .identity(change.reversed)
    case let entry: entry
    }
  }

  public mutating func didUndo(_ applied: SessionIdentityChange) {
    redoStack.append(applied.reversed)
    if redoStack.count > Self.limit { redoStack.removeFirst(redoStack.count - Self.limit) }
  }

  public mutating func popRedo() -> SessionIdentityChange? {
    redoStack.popLast()
  }

  public mutating func didRedo(_ applied: SessionIdentityChange) {
    push(.identity(applied))
  }

  public mutating func keep(only ids: Set<SessionID>) {
    undoStack = undoStack.compactMap { $0.keeping(only: ids) }
    redoStack.removeAll { !ids.contains($0.id) }
  }

  private mutating func push(_ entry: Entry) {
    undoStack.append(entry)
    if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
  }
}
