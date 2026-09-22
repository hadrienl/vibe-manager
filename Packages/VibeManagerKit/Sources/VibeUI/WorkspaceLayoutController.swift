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
  public private(set) var intent: WorkspaceLayout
  public private(set) var columns: WorkspaceColumns
  public private(set) var windowWidth: Double = 0

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
    intent = layout
    columns = WorkspaceLayoutPolicy.resolve(windowWidth: 0, intent: layout)
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
    guard intent.selectedSessionID != id else { return }
    intent.selectedSessionID = id
    scheduleSave()
  }

  public func setSidebarVisible(_ isVisible: Bool) {
    sidebarOverride = isVisible && !proposal.isSidebarVisible
    guard intent.isSidebarVisible != isVisible || sidebarOverride else {
      resolveColumns()
      return
    }
    intent.isSidebarVisible = isVisible
    resolveColumns()
    scheduleSave()
  }

  public func setInspectorVisible(_ isVisible: Bool) {
    inspectorOverride = isVisible && !proposal.isInspectorVisible
    guard intent.isInspectorVisible != isVisible || inspectorOverride else {
      resolveColumns()
      return
    }
    intent.isInspectorVisible = isVisible
    resolveColumns()
    scheduleSave()
  }

  public func toggleSidebar() {
    setSidebarVisible(!columns.isSidebarVisible)
  }

  public func toggleInspector() {
    setInspectorVisible(!columns.isInspectorVisible)
  }

  public func windowWidthChanged(to width: Double) {
    guard width.isFinite, abs(width - windowWidth) >= 1 else { return }
    let previous = proposal
    windowWidth = width
    // A width that changes what the fold proposes ends the exception the user was granted:
    // widening the window is how they get the ordinary behaviour back.
    if proposal != previous {
      sidebarOverride = false
      inspectorOverride = false
    }
    resolveColumns()
  }

  /// Column widths arrive from the views, which measure themselves: SwiftUI hands a split view
  /// the width it should adopt, and never reports back the one the user dragged it to. A column
  /// on its way out reports widths under its own minimum, and those are not an arrangement.
  public func sidebarWidthChanged(to width: Double) {
    guard let measured = WorkspaceLayout.measured(width, in: WorkspaceLayout.sidebarWidthRange),
      abs(measured - intent.sidebarWidth) >= 1
    else {
      return
    }
    intent.sidebarWidth = measured
    scheduleSave()
  }

  public func inspectorWidthChanged(to width: Double) {
    guard let measured = WorkspaceLayout.measured(width, in: WorkspaceLayout.inspectorWidthRange),
      abs(measured - intent.inspectorWidth) >= 1
    else {
      return
    }
    intent.inspectorWidth = measured
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
    intent = layout
    resolveColumns()
  }

  /// What the window width alone would show.
  private var proposal: WorkspaceColumns {
    WorkspaceLayoutPolicy.resolve(windowWidth: windowWidth, intent: intent)
  }

  private func resolveColumns() {
    let proposal = proposal
    columns = WorkspaceColumns(
      isSidebarVisible: proposal.isSidebarVisible || sidebarOverride,
      isInspectorVisible: proposal.isInspectorVisible || inspectorOverride
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
