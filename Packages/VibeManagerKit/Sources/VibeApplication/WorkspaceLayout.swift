import Foundation
import VibeDomain

/// Where the user left the workspace: what was selected, which columns were open, how wide.
///
/// This is interface state, and it is deliberately kept out of `sessions.json`. A window width
/// is a preference of this Mac, not a fact about the work, and a layout written next to the
/// sessions would make every change of interface a change of the persisted session schema.
public struct WorkspaceLayout: Equatable, Sendable, Codable {
  public static let sidebarWidthRange: ClosedRange<Double> = 220...360
  public static let inspectorWidthRange: ClosedRange<Double> = 260...420

  public var selectedSessionID: SessionID?
  /// What the user asked for, not what is currently on screen. A column folded because the
  /// window got narrow must come back when the window is widened again.
  public var isSidebarVisible: Bool
  public var isInspectorVisible: Bool
  public var sidebarWidth: Double
  public var inspectorWidth: Double

  public init(
    selectedSessionID: SessionID? = nil,
    isSidebarVisible: Bool = true,
    isInspectorVisible: Bool = true,
    sidebarWidth: Double = 280,
    inspectorWidth: Double = 300
  ) {
    self.selectedSessionID = selectedSessionID
    self.isSidebarVisible = isSidebarVisible
    self.isInspectorVisible = isInspectorVisible
    self.sidebarWidth = Self.sidebarWidthRange.clamping(sidebarWidth, fallback: 280)
    self.inspectorWidth = Self.inspectorWidthRange.clamping(inspectorWidth, fallback: 300)
  }

  private enum CodingKeys: String, CodingKey {
    case selectedSessionID, isSidebarVisible, isInspectorVisible, sidebarWidth, inspectorWidth
  }

  /// Decoding routes through the designated initializer, so a width written by a future build,
  /// or edited by hand in the preferences, is bounded exactly like one set by a drag.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      selectedSessionID: try container.decodeIfPresent(SessionID.self, forKey: .selectedSessionID),
      isSidebarVisible: try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true,
      isInspectorVisible: try container.decodeIfPresent(Bool.self, forKey: .isInspectorVisible)
        ?? true,
      sidebarWidth: try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 280,
      inspectorWidth: try container.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 300
    )
  }
}

extension ClosedRange where Bound == Double {
  /// Bounds a measured width. A width that is not a number at all — an unmeasured column, a
  /// corrupted preference — falls back rather than propagating into the layout.
  public func clamping(_ value: Double, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}

/// The columns actually shown, once the window's width has had its say.
public struct WorkspaceColumns: Equatable, Sendable {
  public let isSidebarVisible: Bool
  public let isInspectorVisible: Bool

  public init(isSidebarVisible: Bool, isInspectorVisible: Bool) {
    self.isSidebarVisible = isSidebarVisible
    self.isInspectorVisible = isInspectorVisible
  }
}

/// Decides which columns fit, and is a pure function so the rule can be tested without a window.
public enum WorkspaceLayoutPolicy {
  /// Below this width the inspector is folded: the terminal would be left with less than a
  /// readable eighty columns.
  public static let inspectorThreshold: Double = 1_040
  /// Below this width the sidebar folds too, and is reached through its toolbar button.
  public static let sidebarThreshold: Double = 820

  public static func resolve(windowWidth: Double, intent: WorkspaceLayout) -> WorkspaceColumns {
    // An unmeasured window follows the user's intent rather than guessing it away: the first
    // layout pass must not fold columns that the window is in fact wide enough for.
    guard windowWidth.isFinite, windowWidth > 0 else {
      return WorkspaceColumns(
        isSidebarVisible: intent.isSidebarVisible,
        isInspectorVisible: intent.isInspectorVisible
      )
    }

    return WorkspaceColumns(
      isSidebarVisible: intent.isSidebarVisible && windowWidth >= sidebarThreshold,
      isInspectorVisible: intent.isInspectorVisible && windowWidth >= inspectorThreshold
    )
  }
}

/// Reading and writing the layout, without telling the interface where it is kept.
public protocol WorkspaceLayoutStore: Sendable {
  func load() async -> WorkspaceLayout
  func save(_ layout: WorkspaceLayout) async
}
