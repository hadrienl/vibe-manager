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
  /// How much of the inspector's height the Git pane takes, the session's notes having the rest.
  public static let inspectorSplitRange: ClosedRange<Double> = 0.25...0.85
  /// The session's web view (#69), beside the terminal.
  public static let browserWidthRange: ClosedRange<Double> = 380...1_200

  public var selectedSessionID: SessionID?
  /// What the user asked for, not what is currently on screen. A column folded because the
  /// window got narrow must come back when the window is widened again.
  public var isSidebarVisible: Bool
  public var isInspectorVisible: Bool
  public var sidebarWidth: Double
  public var inspectorWidth: Double
  /// Which part of the history the sidebar is showing, and in what order. It belongs here for
  /// the same reason as the columns: it is how the user arranged their view, not a fact about
  /// the work, and it must be found again exactly as it was left.
  public var sessionFilter: SessionFilter
  /// The share of the inspector given to Git, above the notes. Bounded both ways so that neither
  /// pane can be dragged out of reach.
  public var inspectorSplit: Double
  /// Whether the agent and the initial prompt are shown under the notes. The notes come first in
  /// that pane; the rest folds away for whoever wants the room.
  public var isSessionDetailsExpanded: Bool
  /// The width of the web view, common to every session: whether it is shown is the session's own
  /// business (#69), how wide it is is this Mac's.
  public var browserWidth: Double
  /// Which pane is shown above the notes: the session's activity (#36) or Git.
  public var inspectorTopTab: InspectorTopTab
  /// One list, or one section per working folder (#27). Flat until the user asks: grouping
  /// rearranges the sidebar, and it is not the application's to do that unasked.
  public var sidebarMode: SidebarMode
  /// The folders whose group is folded. Never pruned: a group that went away because all of its
  /// sessions were archived folds back the way it was if it returns.
  public var collapsedFolders: Set<SessionFolderKey>

  public init(
    selectedSessionID: SessionID? = nil,
    isSidebarVisible: Bool = true,
    isInspectorVisible: Bool = true,
    sidebarWidth: Double = 280,
    inspectorWidth: Double = 300,
    sessionFilter: SessionFilter = SessionFilter(),
    inspectorSplit: Double = 0.6,
    isSessionDetailsExpanded: Bool = true,
    browserWidth: Double = 520,
    inspectorTopTab: InspectorTopTab = .activity,
    sidebarMode: SidebarMode = .flat,
    collapsedFolders: Set<SessionFolderKey> = []
  ) {
    self.selectedSessionID = selectedSessionID
    self.isSidebarVisible = isSidebarVisible
    self.isInspectorVisible = isInspectorVisible
    self.sidebarWidth = Self.bounded(sidebarWidth, in: Self.sidebarWidthRange, fallback: 280)
    self.inspectorWidth = Self.bounded(inspectorWidth, in: Self.inspectorWidthRange, fallback: 300)
    self.sessionFilter = sessionFilter
    self.inspectorSplit = Self.bounded(inspectorSplit, in: Self.inspectorSplitRange, fallback: 0.6)
    self.isSessionDetailsExpanded = isSessionDetailsExpanded
    self.browserWidth = Self.bounded(browserWidth, in: Self.browserWidthRange, fallback: 520)
    self.inspectorTopTab = inspectorTopTab
    self.sidebarMode = sidebarMode
    self.collapsedFolders = collapsedFolders
  }

  private enum CodingKeys: String, CodingKey {
    case selectedSessionID, isSidebarVisible, isInspectorVisible, sidebarWidth, inspectorWidth
    case sessionFilter, inspectorSplit, isSessionDetailsExpanded, browserWidth, inspectorTopTab
    case sidebarMode, collapsedFolders
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
      inspectorWidth: try container.decodeIfPresent(Double.self, forKey: .inspectorWidth) ?? 300,
      sessionFilter: try container.decodeIfPresent(SessionFilter.self, forKey: .sessionFilter)
        ?? SessionFilter(),
      inspectorSplit: try container.decodeIfPresent(Double.self, forKey: .inspectorSplit) ?? 0.6,
      isSessionDetailsExpanded: try container.decodeIfPresent(
        Bool.self, forKey: .isSessionDetailsExpanded) ?? true,
      browserWidth: (try? container.decodeIfPresent(Double.self, forKey: .browserWidth)) ?? 520,
      // A tab written by a later version and unknown here falls back rather than failing the
      // whole layout.
      inspectorTopTab: (try? container.decodeIfPresent(
        InspectorTopTab.self, forKey: .inspectorTopTab)) ?? .activity,
      // Each on its own terms, like the filter: a mode written by a later build costs the user
      // the grouping at worst, never the rest of the layout.
      sidebarMode: (try? container.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode))
        ?? .flat,
      collapsedFolders: (try? container.decodeIfPresent(
        Set<SessionFolderKey>.self, forKey: .collapsedFolders)) ?? []
    )
  }
}

/// The panes the top of the inspector switches between.
public enum InspectorTopTab: String, Hashable, Codable, Sendable, CaseIterable {
  case activity
  case git
}

extension WorkspaceLayout {
  /// Bounds a stored width. A width that is not a number at all — a corrupted preference, an
  /// unmeasured column — falls back rather than propagating into the layout.
  public static func bounded(
    _ value: Double,
    in range: ClosedRange<Double>,
    fallback: Double
  ) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  /// The width a column just measured, or `nil` when that measurement says nothing about what
  /// the user wants.
  ///
  /// A column being folded, or animating towards it, reports widths well under its own minimum,
  /// down to zero. Bounding those into the range would answer with the smallest allowed width
  /// and overwrite the width the user actually dragged to — so they are ignored instead.
  public static func measured(_ value: Double, in range: ClosedRange<Double>) -> Double? {
    guard value.isFinite, value >= range.lowerBound else { return nil }
    return min(value, range.upperBound)
  }
}

/// Where the session's web view goes, once the window's width has had its say (#69).
public enum BrowserPlacement: Equatable, Sendable {
  /// Not asked for.
  case hidden
  /// Beside the terminal.
  case beside
  /// The window is too narrow for both: the terminal and the web view take turns in the same
  /// place, rather than both shrinking below what either can be used at.
  case alternating
}

/// The columns actually shown, once the window's width has had its say.
public struct WorkspaceColumns: Equatable, Sendable {
  public let isSidebarVisible: Bool
  public let isInspectorVisible: Bool
  public let browser: BrowserPlacement

  public init(
    isSidebarVisible: Bool, isInspectorVisible: Bool, browser: BrowserPlacement = .hidden
  ) {
    self.isSidebarVisible = isSidebarVisible
    self.isInspectorVisible = isInspectorVisible
    self.browser = browser
  }
}

/// Decides which columns fit, and is a pure function so the rule can be tested without a window.
public enum WorkspaceLayoutPolicy {
  /// Below this width the inspector is folded: the terminal would be left with less than a
  /// readable eighty columns.
  public static let inspectorThreshold: Double = 1_040
  /// Below this width the sidebar folds too, and is reached through its toolbar button.
  public static let sidebarThreshold: Double = 820

  /// With the web view beside the terminal, the same order holds with more room asked for: the
  /// inspector first, then the sidebar, and last the web view stops sitting beside the terminal.
  /// Each threshold keeps the terminal at a readable eighty columns (about 560 points) next to a
  /// web view at its narrowest (380), plus the columns still shown.
  public static let inspectorThresholdWithBrowser: Double = 1_600
  public static let sidebarThresholdWithBrowser: Double = 1_180
  public static let browserBesideThreshold: Double = 900

  /// Which columns the window is wide enough to hold, whatever the user asked for.
  ///
  /// An unmeasured window holds everything: the first layout pass must not fold columns that the
  /// window is in fact wide enough for.
  public static func allowances(
    windowWidth: Double, isBrowserRequested: Bool = false
  ) -> WorkspaceColumns {
    guard windowWidth.isFinite, windowWidth > 0 else {
      return WorkspaceColumns(
        isSidebarVisible: true, isInspectorVisible: true,
        browser: isBrowserRequested ? .beside : .hidden)
    }
    guard isBrowserRequested else {
      return WorkspaceColumns(
        isSidebarVisible: windowWidth >= sidebarThreshold,
        isInspectorVisible: windowWidth >= inspectorThreshold
      )
    }
    return WorkspaceColumns(
      isSidebarVisible: windowWidth >= sidebarThresholdWithBrowser,
      isInspectorVisible: windowWidth >= inspectorThresholdWithBrowser,
      browser: windowWidth >= browserBesideThreshold ? .beside : .alternating
    )
  }

  public static func resolve(
    windowWidth: Double, intent: WorkspaceLayout, isBrowserRequested: Bool = false
  ) -> WorkspaceColumns {
    let allowances = allowances(windowWidth: windowWidth, isBrowserRequested: isBrowserRequested)
    return WorkspaceColumns(
      isSidebarVisible: intent.isSidebarVisible && allowances.isSidebarVisible,
      isInspectorVisible: intent.isInspectorVisible && allowances.isInspectorVisible,
      browser: allowances.browser
    )
  }
}

/// Reading and writing the layout, without telling the interface where it is kept.
public protocol WorkspaceLayoutStore: Sendable {
  func load() async -> WorkspaceLayout
  func save(_ layout: WorkspaceLayout) async
}
