import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Keeps the layout the user arranged, and hands the views the one that fits the window.
///
/// The intent and the result are held apart on purpose. Folding a column because the window is
/// narrow must not be recorded as a decision the user made, otherwise widening the window again
/// would leave them with the columns the application chose instead of the ones they had.
@MainActor
@Observable
public final class WorkspaceLayoutController {
  /// What the user asked for, with the column widths last measured.
  public var intent: WorkspaceLayout {
    var layout = settings
    layout.sidebarWidth = measuredWidths.sidebar
    layout.inspectorWidth = measuredWidths.inspector
    layout.browserWidth = browserWidth
    return layout
  }
  public private(set) var columns: WorkspaceColumns
  public private(set) var windowWidth: Double = 0

  /// Everything in the layout but the column widths — what the views read.
  private var settings: WorkspaceLayout
  /// Measured during layout, and only ever written back to the store: no view draws from them.
  ///
  /// Kept out of observation on purpose. The root reads the layout, so a width written into it
  /// invalidated the whole window from inside the layout pass that measured it — split view,
  /// inspector and toolbar — and they measured again. A window snapped to half the screen
  /// resizes in a single display cycle: AppKit counted past its loop guard and threw, which with
  /// an application built for development is a crash.
  @ObservationIgnored private var measuredWidths: (sidebar: Double, inspector: Double)

  /// The web view's width (#69). Observed, unlike the columns' measured widths: it is not
  /// measured from a layout pass but set by its own handle, and the panel is drawn at it.
  public private(set) var browserWidth: Double

  /// Whether the selected session asks for its web view (#69). It is the session's, not the
  /// layout's: the workspace says it here each time the selection or the session changes it.
  public private(set) var isBrowserRequested = false
  /// Which of the two takes the room when they alternate: the web view, or the terminal.
  public private(set) var showsBrowserWhenAlternating = true

  /// A column the user asked for while the window was too narrow for it.
  ///
  /// Without this, the fold and the toggle fight: the binding reads the folded result and writes
  /// the intent, so under the threshold the sidebar button and ⌃⌘S did nothing at all and the
  /// session list could not be reached. An explicit ask outranks the fold, until the window
  /// width changes what the fold itself proposes.
  private var sidebarOverride = false
  private var inspectorOverride = false

  private let store: (any WorkspaceLayoutStore)?
  private let saveDelay: Duration
  private var saveTask: Task<Void, Never>?

  public init(
    store: (any WorkspaceLayoutStore)? = nil,
    layout: WorkspaceLayout = WorkspaceLayout(),
    saveDelay: Duration = .milliseconds(500)
  ) {
    self.store = store
    self.saveDelay = saveDelay
    settings = layout
    measuredWidths = (layout.sidebarWidth, layout.inspectorWidth)
    browserWidth = layout.browserWidth
    columns = WorkspaceLayoutPolicy.resolve(windowWidth: 0, intent: layout)
  }

  public func setBrowserRequested(_ isRequested: Bool) {
    guard isRequested != isBrowserRequested else { return }
    let previous = allowances
    isBrowserRequested = isRequested
    // The web view coming or going changes what the width allows, as a resize would.
    dropOverrides(from: previous)
    resolveColumns()
  }

  /// In a window too narrow for both, which one is shown. Asking for one of them is what brings it
  /// forward: the web view when an agent opens a page, the terminal when it is focused.
  public func setShowsBrowserWhenAlternating(_ showsBrowser: Bool) {
    showsBrowserWhenAlternating = showsBrowser
  }

  /// Whether the terminal is on screen at all: not when the web view has the room to itself.
  public var isTerminalShown: Bool {
    columns.browser != .alternating || !showsBrowserWhenAlternating
  }

  /// Whether the web view is on screen.
  public var isBrowserShown: Bool {
    switch columns.browser {
    case .hidden: return false
    case .beside: return true
    case .alternating: return showsBrowserWhenAlternating
    }
  }

  public func browserWidthChanged(to width: Double) {
    let bounded = WorkspaceLayout.bounded(
      width, in: WorkspaceLayout.browserWidthRange, fallback: browserWidth)
    guard abs(bounded - browserWidth) >= 1 else { return }
    browserWidth = bounded
    scheduleSave()
  }

  /// Reads back the stored layout and reports the selection it carried, which the caller is
  /// free to ignore if that session is gone.
  @discardableResult
  public func restore() async -> SessionID? {
    guard let store else { return intent.selectedSessionID }
    apply(await store.load())
    return intent.selectedSessionID
  }

  public func select(_ id: SessionID?) {
    guard settings.selectedSessionID != id else { return }
    settings.selectedSessionID = id
    scheduleSave()
  }

  public var filter: SessionFilter {
    intent.sessionFilter
  }

  /// The scope, the sort and the facets are kept. The search text never reaches here — the
  /// workspace holds it in memory — so typing never restarts the delay this save waits out.
  public func setFilter(_ filter: SessionFilter) {
    updateIntent { $0.sessionFilter = filter }
  }

  /// Showing a column the window is too narrow for is an exception, not an arrangement: it is
  /// recorded as an override and leaves the stored intent alone, so that hiding it again only
  /// withdraws the exception and widening the window still restores the columns the user had.
  public func setSidebarVisible(_ isVisible: Bool) {
    if isVisible {
      if allowances.isSidebarVisible {
        sidebarOverride = false
        updateIntent { $0.isSidebarVisible = true }
      } else {
        sidebarOverride = true
      }
    } else if sidebarOverride {
      sidebarOverride = false
    } else {
      updateIntent { $0.isSidebarVisible = false }
    }
    resolveColumns()
  }

  public func setInspectorVisible(_ isVisible: Bool) {
    if isVisible {
      if allowances.isInspectorVisible {
        inspectorOverride = false
        updateIntent { $0.isInspectorVisible = true }
      } else {
        inspectorOverride = true
      }
    } else if inspectorOverride {
      inspectorOverride = false
    } else {
      updateIntent { $0.isInspectorVisible = false }
    }
    resolveColumns()
  }

  public func toggleSidebar() {
    setSidebarVisible(!columns.isSidebarVisible)
  }

  public func toggleInspector() {
    setInspectorVisible(!columns.isInspectorVisible)
  }

  public func windowWidthChanged(to width: Double) {
    guard width.isFinite, abs(width - windowWidth) >= 1 else { return }
    let previous = allowances
    windowWidth = width
    // A width that changes what a column is allowed to do ends the exception the user was
    // granted for that column: widening the window is how they get the ordinary behaviour back.
    // Each column answers for itself, so revealing the inspector by hand does not survive, or
    // die with, a width that only concerns the sidebar.
    dropOverrides(from: previous)
    resolveColumns()
  }

  private func dropOverrides(from previous: WorkspaceColumns) {
    let current = allowances
    if current.isSidebarVisible != previous.isSidebarVisible {
      sidebarOverride = false
    }
    if current.isInspectorVisible != previous.isInspectorVisible {
      inspectorOverride = false
    }
  }

  /// Column widths arrive from the views, which measure themselves: SwiftUI hands a split view
  /// the width it should adopt, and never reports back the one the user dragged it to. A column
  /// on its way out reports widths under its own minimum, and those are not an arrangement.
  public func sidebarWidthChanged(to width: Double) {
    guard let measured = WorkspaceLayout.measured(width, in: WorkspaceLayout.sidebarWidthRange),
      abs(measured - measuredWidths.sidebar) >= 1
    else {
      return
    }
    measuredWidths.sidebar = measured
    scheduleSave()
  }

  public func inspectorWidthChanged(to width: Double) {
    guard let measured = WorkspaceLayout.measured(width, in: WorkspaceLayout.inspectorWidthRange),
      abs(measured - measuredWidths.inspector) >= 1
    else {
      return
    }
    measuredWidths.inspector = measured
    scheduleSave()
  }

  /// The divider between Git and the notes, as a share of the inspector's height.
  public func inspectorSplitChanged(to fraction: Double) {
    guard fraction.isFinite else { return }
    let bounded = WorkspaceLayout.bounded(
      fraction, in: WorkspaceLayout.inspectorSplitRange, fallback: settings.inspectorSplit)
    guard abs(bounded - settings.inspectorSplit) >= 0.005 else { return }
    settings.inspectorSplit = bounded
    scheduleSave()
  }

  /// One list, or one section per working folder (#27).
  public var sidebarMode: SidebarMode {
    settings.sidebarMode
  }

  public func setSidebarMode(_ mode: SidebarMode) {
    updateIntent { $0.sidebarMode = mode }
  }

  /// The folders whose group the user folded.
  public var collapsedFolders: Set<SessionFolderKey> {
    settings.collapsedFolders
  }

  public func setCollapsed(_ isCollapsed: Bool, folders: Set<SessionFolderKey>) {
    updateIntent {
      if isCollapsed {
        $0.collapsedFolders.formUnion(folders)
      } else {
        $0.collapsedFolders.subtract(folders)
      }
    }
  }

  public var isArchivedSectionExpanded: Bool {
    settings.isArchivedSectionExpanded
  }

  public func setArchivedSectionExpanded(_ isExpanded: Bool) {
    updateIntent { $0.isArchivedSectionExpanded = isExpanded }
  }

  /// Whether the agent and the initial prompt are unfolded under the notes.
  public func setSessionDetailsExpanded(_ isExpanded: Bool) {
    guard settings.isSessionDetailsExpanded != isExpanded else { return }
    settings.isSessionDetailsExpanded = isExpanded
    scheduleSave()
  }

  /// Activity or Git, above the notes.
  public func setInspectorTopTab(_ tab: InspectorTopTab) {
    guard settings.inspectorTopTab != tab else { return }
    settings.inspectorTopTab = tab
    scheduleSave()
  }

  /// Writes whatever is pending right away. Called when the application is about to quit, where
  /// waiting out the delay would mean losing the last arrangement.
  public func flush() async {
    saveTask?.cancel()
    saveTask = nil
    await store?.save(intent)
  }

  private func apply(_ layout: WorkspaceLayout) {
    settings = layout
    measuredWidths = (layout.sidebarWidth, layout.inspectorWidth)
    browserWidth = layout.browserWidth
    resolveColumns()
  }

  /// What the window width alone would show.
  private var proposal: WorkspaceColumns {
    WorkspaceLayoutPolicy.resolve(
      windowWidth: windowWidth, intent: intent, isBrowserRequested: isBrowserRequested)
  }

  /// What the window is wide enough to hold, whatever the user asked for.
  private var allowances: WorkspaceColumns {
    WorkspaceLayoutPolicy.allowances(
      windowWidth: windowWidth, isBrowserRequested: isBrowserRequested)
  }

  private func updateIntent(_ change: (inout WorkspaceLayout) -> Void) {
    var updated = settings
    change(&updated)
    guard updated != settings else { return }
    settings = updated
    scheduleSave()
  }

  private func resolveColumns() {
    let proposal = proposal
    columns = WorkspaceColumns(
      isSidebarVisible: proposal.isSidebarVisible || sidebarOverride,
      isInspectorVisible: proposal.isInspectorVisible || inspectorOverride,
      browser: proposal.browser
    )
  }

  /// One write per pause instead of one per event: dragging a separator produces a continuous
  /// stream of widths, and none of the intermediate ones is worth a trip to the preferences.
  private func scheduleSave() {
    guard let store else { return }
    saveTask?.cancel()
    let layout = intent
    saveTask = Task { [store, saveDelay] in
      try? await Task.sleep(for: saveDelay)
      guard !Task.isCancelled else { return }
      await store.save(layout)
    }
  }
}
