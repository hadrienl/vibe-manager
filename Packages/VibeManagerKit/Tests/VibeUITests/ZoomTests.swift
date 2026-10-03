import Foundation
import Testing
import VibeApplication
import VibeConversationUI

@testable import VibeUI

/// View › Zoom In, Zoom Out and Actual Size (#229): the size of the conversations' and the
/// terminals' text, kept with the Conversation settings.
@Suite("The zoom of the text")
@MainActor
struct ZoomTests {
  private func model(_ store: InMemoryConversationAppearanceStore) -> AppModel {
    AppModel(
      repository: WorkspaceRepository(sessions: []),
      conversations: ConversationWorkspace(store: store))
  }

  @Test("Zoom In and Zoom Out step through the sizes, and stop at their ends")
  func steps() {
    let store = InMemoryConversationAppearanceStore()
    let model = model(store)
    #expect(model.textSize == .standard)
    #expect(model.isActualSize)

    model.zoomIn()
    #expect(model.textSize == .large)
    model.zoomIn()
    #expect(model.textSize == .extraLarge)
    #expect(!model.canZoomIn)
    model.zoomIn()
    #expect(model.textSize == .extraLarge)

    model.resetZoom()
    #expect(model.textSize == .standard)
    model.zoomOut()
    #expect(model.textSize == .small)
    #expect(!model.canZoomOut)
  }

  @Test("The size chosen is kept for the next launch")
  func kept() {
    let store = InMemoryConversationAppearanceStore()
    model(store).zoomIn()

    #expect(store.appearance.textSize == .large)
    #expect(model(store).textSize == .large)
  }

  @Test("The terminal and the fixed sizes of the conversation grow with the text")
  func scaled() {
    let standard = ConversationAppearance.TextSize.standard
    #expect(standard.scaled(11) == 11)
    #expect(standard.terminalPointSize == 13)

    let largest = ConversationAppearance.TextSize.extraLarge
    #expect(largest.scaled(11) > 11)
    #expect(largest.terminalPointSize > 13)
    #expect(ConversationAppearance.TextSize.small.terminalPointSize < 13)
  }
}
