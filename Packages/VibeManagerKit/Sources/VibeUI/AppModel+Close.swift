import AppKit
import Foundation

/// What ⌘W closes in the workspace (#165): the element inside the session that holds the keyboard,
/// never the session itself, which is ⇧⌘W — as in Safari, ⌘W for the tab and ⇧⌘W for the window,
/// the session playing the window's part.
public enum InnerCloseTarget: Equatable, Sendable {
  /// The side terminal in front of the drawer, the keyboard being in the drawer (#43).
  case drawerTerminal
  /// The web view's tab in front, the keyboard being in its page or its address bar (ADR 0023).
  case webTab
}

extension AppModel {
  /// What ⌘W would close, from where the keyboard is; `nil` when it is in none of the session's
  /// inner elements — the agent's terminal, the conversation, the sidebar, the inspector: ⌘W is
  /// then unavailable, and the session is left alone.
  public var innerCloseTarget: InnerCloseTarget? {
    if closesDrawerTerminal { return .drawerTerminal }
    if closesWebTab { return .webTab }
    return nil
  }

  /// ⌘W: closes the inner element that holds the keyboard, and beeps when there is none.
  public func closeInnerElement() {
    switch innerCloseTarget {
    case .drawerTerminal: requestCloseDrawerTerminal()
    case .webTab: closeWebTab()
    case nil: beep()
    }
  }
}
