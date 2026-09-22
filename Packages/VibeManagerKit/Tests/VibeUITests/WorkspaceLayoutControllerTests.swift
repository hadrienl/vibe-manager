import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A layout store that records what it was asked to keep.
actor RecordingLayoutStore: WorkspaceLayoutStore {
  private var layout: WorkspaceLayout
  private(set) var saves: [WorkspaceLayout] = []

  init(layout: WorkspaceLayout = WorkspaceLayout()) {
    self.layout = layout
  }

  func load() -> WorkspaceLayout {
    layout
  }

  func save(_ layout: WorkspaceLayout) {
    self.layout = layout
    saves.append(layout)
  }
}

@MainActor
@Suite("Keeping the arrangement the user made")
struct WorkspaceLayoutControllerTests {
  @Test("The stored layout comes back, selection included")
  func restoresWhatWasStored() async {
    let selected = SessionID()
    let store = RecordingLayoutStore(
      layout: WorkspaceLayout(
        selectedSessionID: selected,
        isInspectorVisible: false,
        sidebarWidth: 320
      )
    )
    let controller = WorkspaceLayoutController(store: store)

    let restored = await controller.restore()

    #expect(restored == selected)
    #expect(controller.intent.sidebarWidth == 320)
    #expect(!controller.columns.isInspectorVisible)
  }

  @Test("A column folded by a narrow window is not recorded as a decision")
  func foldingIsNotAChoice() async {
    let store = RecordingLayoutStore()
    let controller = WorkspaceLayoutController(store: store, saveDelay: .milliseconds(1))

    controller.windowWidthChanged(to: 700)
    #expect(!controller.columns.isInspectorVisible)
    #expect(!controller.columns.isSidebarVisible)
    #expect(controller.intent.isInspectorVisible)

    controller.windowWidthChanged(to: 1_400)
    #expect(controller.columns.isInspectorVisible)
    #expect(controller.columns.isSidebarVisible)
    await #expect(store.saves.isEmpty)
  }

  @Test("Closing a column is recorded, and survives a resize")
  func closingIsAChoice() async {
    let store = RecordingLayoutStore()
    let controller = WorkspaceLayoutController(store: store)

    controller.windowWidthChanged(to: 1_400)
    controller.setInspectorVisible(false)
    await controller.flush()

    #expect(!controller.columns.isInspectorVisible)
    await #expect(store.load().isInspectorVisible == false)
  }

  @Test("A drag is written once, not at every width it passes through")
  func widthsAreWrittenOncePerPause() async throws {
    let store = RecordingLayoutStore()
    let controller = WorkspaceLayoutController(store: store, saveDelay: .milliseconds(20))

    for width in stride(from: 240.0, through: 320.0, by: 4) {
      controller.sidebarWidthChanged(to: width)
    }
    try await Task.sleep(for: .milliseconds(120))

    await #expect(store.saves.count == 1)
    #expect(controller.intent.sidebarWidth == 320)
  }

  @Test("A width outside the range never reaches the layout")
  func widthsAreBounded() async {
    let controller = WorkspaceLayoutController()

    controller.sidebarWidthChanged(to: 10_000)
    controller.inspectorWidthChanged(to: .nan)

    #expect(controller.intent.sidebarWidth == WorkspaceLayout.sidebarWidthRange.upperBound)
    #expect(WorkspaceLayout.inspectorWidthRange.contains(controller.intent.inspectorWidth))
  }

  @Test("Quitting writes what the delay was still holding")
  func flushWritesImmediately() async {
    let store = RecordingLayoutStore()
    let controller = WorkspaceLayoutController(store: store, saveDelay: .seconds(30))
    let selected = SessionID()

    controller.select(selected)
    await controller.flush()

    await #expect(store.load().selectedSessionID == selected)
  }

  @Test("A controller without a store works, and keeps nothing")
  func storelessControllerIsUsable() async {
    let controller = WorkspaceLayoutController()
    let selected = SessionID()

    controller.select(selected)
    let restored = await controller.restore()

    #expect(restored == selected)
  }
}
