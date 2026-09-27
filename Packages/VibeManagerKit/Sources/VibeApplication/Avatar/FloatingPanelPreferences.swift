/// What the floating panel shows when no request waits (#41).
public enum FloatingPanelIdle: String, Hashable, Sendable, CaseIterable {
  /// Nothing: the panel comes with a request and goes with the last one.
  case hidden
  /// The avatar alone, at rest.
  case avatarOnly
}

/// Where the avatar stands on one screen: a point of its visible frame, from 0 to 1 on each axis,
/// so that it survives a change of resolution.
public struct FloatingPanelAnchor: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = min(max(x, 0), 1)
    self.y = min(max(y, 0), 1)
  }
}

/// What the user chose about the floating panel (#41).
@MainActor
public protocol FloatingPanelPreferences: AnyObject {
  /// Requests shown above the other applications. Off by default: #40 unchanged.
  var showsFloatingPanel: Bool { get set }
  var idle: FloatingPanelIdle { get set }
  /// Folded into the avatar alone.
  var isCollapsed: Bool { get set }
  /// Where the avatar stood on each screen, by the screen's stable identifier.
  var anchors: [String: FloatingPanelAnchor] { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryFloatingPanelPreferences: FloatingPanelPreferences {
  public var showsFloatingPanel: Bool
  public var idle: FloatingPanelIdle
  public var isCollapsed: Bool
  public var anchors: [String: FloatingPanelAnchor]

  public init(
    showsFloatingPanel: Bool = false, idle: FloatingPanelIdle = .hidden, isCollapsed: Bool = false,
    anchors: [String: FloatingPanelAnchor] = [:]
  ) {
    self.showsFloatingPanel = showsFloatingPanel
    self.idle = idle
    self.isCollapsed = isCollapsed
    self.anchors = anchors
  }
}
