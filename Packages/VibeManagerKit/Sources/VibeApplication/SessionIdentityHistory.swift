import VibeDomain

/// The renames and badge changes ⌘Z undoes and ⇧⌘Z redoes (#183), for this run of the application.
///
/// Kept apart from the window's undo manager, which every text field shares and the composer empties
/// each time it is sent: a rename there would be lost at the next prompt, and answered by a ⌘Z
/// typed in a terminal.
public struct SessionIdentityHistory: Hashable, Sendable {
  /// How many changes are kept; the oldest go first.
  public static let limit = 50

  public private(set) var undoStack: [SessionIdentityChange] = []
  public private(set) var redoStack: [SessionIdentityChange] = []

  public init() {}

  public var canUndo: Bool { !undoStack.isEmpty }
  public var canRedo: Bool { !redoStack.isEmpty }

  /// A change the user just made: it can be undone, and what was undone before can no longer be
  /// redone.
  public mutating func record(_ change: SessionIdentityChange) {
    push(change, onto: &undoStack)
    redoStack.removeAll()
  }

  /// The change to apply to undo the last one, taken off the stack. The caller applies it and
  /// then says so with `didUndo`, or drops it if the session has changed since.
  public mutating func popUndo() -> SessionIdentityChange? {
    undoStack.popLast()?.reversed
  }

  public mutating func didUndo(_ applied: SessionIdentityChange) {
    push(applied.reversed, onto: &redoStack)
  }

  public mutating func popRedo() -> SessionIdentityChange? {
    redoStack.popLast()
  }

  public mutating func didRedo(_ applied: SessionIdentityChange) {
    push(applied, onto: &undoStack)
  }

  /// Forgets the changes of sessions that are no longer stored.
  public mutating func keep(only ids: Set<SessionID>) {
    undoStack.removeAll { !ids.contains($0.id) }
    redoStack.removeAll { !ids.contains($0.id) }
  }

  private func push(_ change: SessionIdentityChange, onto stack: inout [SessionIdentityChange]) {
    stack.append(change)
    if stack.count > Self.limit { stack.removeFirst(stack.count - Self.limit) }
  }
}
