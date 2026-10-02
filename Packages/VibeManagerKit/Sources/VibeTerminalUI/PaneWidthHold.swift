import SwiftUI

/// The width the panes of a column keep while the column changes size for a moment: the web
/// view's divider dragged, the web view sliding in or out.
///
/// Every session's terminal and conversation stays mounted in the column, and each new width
/// made SwiftUI lay them all out again, and the terminal on screen reflow its whole scrollback
/// and tell its program — at every step of the drag, on the main thread. Held, they are laid out
/// once more, when the column has settled.
public struct PaneWidthHold: Equatable, Sendable {
  public var width: CGFloat
  /// Whether the pane on screen may keep it too: never narrower than the column, what it puts out
  /// of the column is under the web view sliding over it. Otherwise the pane on screen whose
  /// background cannot fill what it would leave bare — a conversation's — follows the column.
  public var isCovered: Bool

  public init(width: CGFloat, isCovered: Bool) {
    self.width = width
    self.isCovered = isCovered
  }
}

extension EnvironmentValues {
  @Entry public var paneWidthHold: PaneWidthHold?
}
