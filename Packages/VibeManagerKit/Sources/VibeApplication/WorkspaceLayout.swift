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
  /// The sections of the context column: their order, which are folded, and their share of the
  /// height (#66). Common to every session.
  public var inspectorSections: InspectorArrangement
  /// The width of the web view, common to every session: whether it is shown is the session's own
  /// business (#69), how wide it is is this Mac's.
  public var browserWidth: Double
  /// One list, or one section per working folder (#27). Flat until the user asks: grouping
  /// rearranges the sidebar, and it is not the application's to do that unasked.
  public var sidebarMode: SidebarMode
  /// The folders whose group is folded. Never pruned: a group that went away because all of its
  /// sessions were archived folds back the way it was if it returns.
  public var collapsedFolders: Set<SessionFolderKey>
  /// How each session the user switched is shown (#38), keyed by its identifier. A session that
  /// is not listed follows the default of the Conversation settings.
  public var sessionPresentations: [String: SessionPresentation]
  /// Whether the palette of pending requests is folded into its count (#40).
  public var isRequestPaletteCollapsed: Bool
  /// The coordinators whose children are folded away in the sidebar (#352). Never pruned, like the
  /// folders.
  public var collapsedCoordinators: Set<SessionID>

  public init(
    selectedSessionID: SessionID? = nil,
    isSidebarVisible: Bool = true,
    isInspectorVisible: Bool = true,
    sidebarWidth: Double = 280,
    inspectorWidth: Double = 300,
    sessionFilter: SessionFilter = SessionFilter(),
    inspectorSections: InspectorArrangement = .default,
    browserWidth: Double = 520,
    sidebarMode: SidebarMode = .flat,
    collapsedFolders: Set<SessionFolderKey> = [],
    sessionPresentations: [String: SessionPresentation] = [:],
    isRequestPaletteCollapsed: Bool = false,
    collapsedCoordinators: Set<SessionID> = []
  ) {
    self.selectedSessionID = selectedSessionID
    self.isSidebarVisible = isSidebarVisible
    self.isInspectorVisible = isInspectorVisible
    self.sidebarWidth = Self.bounded(sidebarWidth, in: Self.sidebarWidthRange, fallback: 280)
    self.inspectorWidth = Self.bounded(inspectorWidth, in: Self.inspectorWidthRange, fallback: 300)
    self.sessionFilter = sessionFilter
    self.inspectorSections = inspectorSections
    self.browserWidth = Self.bounded(browserWidth, in: Self.browserWidthRange, fallback: 520)
    self.sidebarMode = sidebarMode
    self.collapsedFolders = collapsedFolders
    self.sessionPresentations = sessionPresentations
    self.isRequestPaletteCollapsed = isRequestPaletteCollapsed
    self.collapsedCoordinators = collapsedCoordinators
  }

  private enum CodingKeys: String, CodingKey {
    case selectedSessionID, isSidebarVisible, isInspectorVisible, sidebarWidth, inspectorWidth
    case sessionFilter, inspectorSections, browserWidth
    case sidebarMode, collapsedFolders, sessionPresentations
    case isRequestPaletteCollapsed, collapsedCoordinators
  }

  /// What the column was arranged with before #66. Read once, to arrange the sections the same
  /// way, and never written again.
  private enum LegacyKeys: String, CodingKey {
    case inspectorSplit, isSessionDetailsExpanded, inspectorTopTab
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
      inspectorSections: Self.decodeSections(
        from: container, legacy: try decoder.container(keyedBy: LegacyKeys.self)),
      browserWidth: (try? container.decodeIfPresent(Double.self, forKey: .browserWidth)) ?? 520,
      // Each on its own terms, like the filter: a mode written by a later build costs the user
      // the grouping at worst, never the rest of the layout.
      sidebarMode: (try? container.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode))
        ?? .flat,
      collapsedFolders: (try? container.decodeIfPresent(
        Set<SessionFolderKey>.self, forKey: .collapsedFolders)) ?? [],
      // A value a later build wrote, and this one cannot read, costs only this key.
      sessionPresentations: (try? container.decodeIfPresent(
        [String: SessionPresentation].self, forKey: .sessionPresentations)) ?? [:],
      isRequestPaletteCollapsed: (try? container.decodeIfPresent(
        Bool.self, forKey: .isRequestPaletteCollapsed)) ?? false,
      collapsedCoordinators: (try? container.decodeIfPresent(
        Set<SessionID>.self, forKey: .collapsedCoordinators)) ?? []
    )
  }
}

extension WorkspaceLayout {
  /// The sections as stored; or, from a layout written before they existed, the arrangement that
  /// shows what the user had: the same pane on top, the same share of the height against the
  /// notes, and the agent and prompt folded or not as they were. Unreadable, the default.
  private static func decodeSections(
    from container: KeyedDecodingContainer<CodingKeys>,
    legacy: KeyedDecodingContainer<LegacyKeys>
  ) -> InspectorArrangement {
    if container.contains(.inspectorSections) {
      return (try? container.decode(InspectorArrangement.self, forKey: .inspectorSections))
        ?? .default
    }
    let split = try? legacy.decodeIfPresent(Double.self, forKey: .inspectorSplit)
    let details = try? legacy.decodeIfPresent(Bool.self, forKey: .isSessionDetailsExpanded)
    let tab = try? legacy.decodeIfPresent(String.self, forKey: .inspectorTopTab)
    guard split != nil || details != nil || tab != nil else { return .default }
    return migratedSections(split: split, isDetailsExpanded: details, topTab: tab)
  }

  /// The column before #66: Activity or Git on top, one at a time, over the notes, which had
  /// `1 - split` of the height; then the agent, usage and prompt, folded together.
  static func migratedSections(split: Double?, isDetailsExpanded: Bool?, topTab: String?)
    -> InspectorArrangement
  {
    let top = bounded(split ?? 0.6, in: 0.25...0.85, fallback: 0.6)
    let showsGit = topTab == "git"
    let detailsCollapsed = !(isDetailsExpanded ?? true)
    let activity = InspectorArrangement.Entry(id: .activity, isCollapsed: showsGit, weight: top)
    let git = InspectorArrangement.Entry(id: .git, isCollapsed: !showsGit, weight: top)
    return InspectorArrangement(entries: [
      showsGit ? git : activity,
      showsGit ? activity : git,
      .init(id: .notes, isCollapsed: false, weight: 1 - top),
      .init(id: .agent, isCollapsed: detailsCollapsed),
      .init(id: .usage, isCollapsed: detailsCollapsed),
      .init(id: .prompt, isCollapsed: detailsCollapsed),
    ])
  }

  public func presentation(of id: SessionID, default fallback: SessionPresentation)
    -> SessionPresentation
  {
    sessionPresentations[id.description] ?? fallback
  }

  /// Forgets the sessions that are gone, so that the preference does not grow forever.
  public mutating func keepPresentations(of ids: Set<SessionID>) {
    let kept = Set(ids.map(\.description))
    sessionPresentations = sessionPresentations.filter { kept.contains($0.key) }
  }

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

  /// The widest the web view may be beside a terminal in `containerWidth`: the terminal keeps
  /// `terminalMinimum`, the web view gives way first, down to its own minimum.
  public static func browserWidthUpperBound(
    in containerWidth: Double, handle: Double, terminalMinimum: Double
  ) -> Double {
    let available = containerWidth - terminalMinimum - handle
    guard available.isFinite else { return browserWidthRange.lowerBound }
    return max(browserWidthRange.lowerBound, available)
  }

  /// The web view's width that gives it and the terminal the same width, as far as the bounds
  /// allow: the terminal keeps its minimum, the web view stays within `browserWidthRange` (#218).
  public static func centeredBrowserWidth(
    in containerWidth: Double, handle: Double, terminalMinimum: Double
  ) -> Double {
    let upper = min(
      browserWidthRange.upperBound,
      browserWidthUpperBound(
        in: containerWidth, handle: handle, terminalMinimum: terminalMinimum))
    let half = (containerWidth - handle) / 2
    guard half.isFinite else { return browserWidthRange.lowerBound }
    return min(max(half, browserWidthRange.lowerBound), upper)
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
