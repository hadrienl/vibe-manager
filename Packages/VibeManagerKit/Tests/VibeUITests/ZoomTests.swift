import AppKit
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

  @Test("The terminal and the fixed sizes grow with a larger text, never shrink with a smaller")
  func scaled() {
    let standard = ConversationAppearance.TextSize.standard
    #expect(standard.scaled(11) == 11)
    #expect(standard.terminalPointSize == 13)

    // A smaller text, chosen before the zoom existed, made only the messages smaller.
    let small = ConversationAppearance.TextSize.small
    #expect(small.scaled(11) == 11)
    #expect(small.terminalPointSize == 13)

    // To the half-point.
    #expect(ConversationAppearance.TextSize.large.terminalPointSize == 14.5)
    #expect(ConversationAppearance.TextSize.extraLarge.terminalPointSize == 16)
    #expect(ConversationAppearance.TextSize.extraLarge.scaled(11) > 11)
  }

  private func key(
    _ character: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: character, charactersIgnoringModifiers: character,
      isARepeat: false, keyCode: keyCode)!
  }

  @Test("The zoom's keys are read on a US and on a French keyboard")
  func keys() {
    // US: ⌘= unshifted, ⌘+ with shift, ⌘−, ⌘0.
    #expect(ZoomCommand.matching(key("=", keyCode: 24)) == .zoomIn)
    #expect(ZoomCommand.matching(key("+", keyCode: 24, [.command, .shift])) == .zoomIn)
    #expect(ZoomCommand.matching(key("-", keyCode: 27)) == .zoomOut)
    #expect(ZoomCommand.matching(key("0", keyCode: 29)) == .actualSize)
    // French AZERTY: = and − unshifted, + is ⇧=, 0 is ⇧à — and ⌘à means it too.
    #expect(ZoomCommand.matching(key("=", keyCode: 24)) == .zoomIn)
    #expect(ZoomCommand.matching(key("+", keyCode: 24, [.command, .shift])) == .zoomIn)
    #expect(ZoomCommand.matching(key("-", keyCode: 22)) == .zoomOut)
    #expect(ZoomCommand.matching(key("0", keyCode: 29, [.command, .shift])) == .actualSize)
    #expect(ZoomCommand.matching(key("à", keyCode: 29)) == .actualSize)
    // Not the zoom: other modifiers, or no ⌘.
    #expect(ZoomCommand.matching(key("=", keyCode: 24, [.command, .option])) == nil)
    #expect(ZoomCommand.matching(key("=", keyCode: 24, [])) == nil)
    #expect(ZoomCommand.matching(key("t", keyCode: 17)) == nil)
  }

  @Test("The floating panel of the requests keeps its ⌘−")
  func panelKeepsItsKeys() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    #expect(ZoomKeyMonitor.command(for: key("-", keyCode: 27), in: panel) == nil)
    #expect(ZoomKeyMonitor.command(for: key("-", keyCode: 27), in: window) == .zoomOut)
    #expect(ZoomKeyMonitor.command(for: key("=", keyCode: 24), in: nil) == .zoomIn)
  }

  @Test("A key of the zoom changes the size")
  func zoomByCommand() {
    let model = model(InMemoryConversationAppearanceStore())
    model.zoom(.zoomIn)
    #expect(model.textSize == .large)
    model.zoom(.actualSize)
    #expect(model.textSize == .standard)
    model.zoom(.zoomOut)
    #expect(model.textSize == .small)
  }
}
