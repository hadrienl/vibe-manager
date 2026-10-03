import Testing

@testable import VibeUI

/// The sidebar's words of a state, and the drawer's marks, read by more than their colour (#231).
@Suite("Status colours that every reader can tell apart")
struct StatusInkTests {
  @Test("A state that asks for the eye says it in the label colour, its colour kept on the symbol")
  func wordsInLabelColour() {
    #expect(SessionStatusSeverity.attention.wordsInLabelColour)
    #expect(SessionStatusSeverity.error.wordsInLabelColour)
    #expect(SessionStatusSeverity.active.wordsInLabelColour)
    #expect(!SessionStatusSeverity.normal.wordsInLabelColour)
  }

  @Test("With Differentiate Without Color, an ended shell is a ring, new output a dot")
  func drawerMarks() {
    #expect(DrawerNewsMark.isRing(.ended, differentiatingWithoutColor: true))
    #expect(!DrawerNewsMark.isRing(.output, differentiatingWithoutColor: true))
    #expect(!DrawerNewsMark.isRing(.ended, differentiatingWithoutColor: false))
  }
}
