import AppKit
import Testing
import VibeApplication

@testable import VibeUI

/// The sidebar's words of a state, and the drawer's marks, read by more than their colour (#231).
@Suite("Status colours that every reader can tell apart")
struct StatusInkTests {
  /// What a caption in `colour` reads at on the window's background, in `appearance`, as WCAG
  /// measures it: the colour laid over the background first, for a translucent label colour.
  @MainActor
  private func contrast(of colour: NSColor, in appearance: NSAppearance.Name) -> Double {
    var ratio = 0.0
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
      let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
      let foreground = colour.usingColorSpace(.sRGB)!
      let alpha = foreground.alphaComponent
      func blended(_ top: CGFloat, _ bottom: CGFloat) -> Double { Double(top * alpha + bottom * (1 - alpha)) }
      let text = ThemeColor(
        red: blended(foreground.redComponent, background.redComponent),
        green: blended(foreground.greenComponent, background.greenComponent),
        blue: blended(foreground.blueComponent, background.blueComponent))
      let behind = ThemeColor(
        red: Double(background.redComponent), green: Double(background.greenComponent),
        blue: Double(background.blueComponent))
      ratio = text.contrast(with: behind)
    }
    return ratio
  }

  @Test("A state that asks for the eye says it in the label colour, its colour kept on the symbol")
  func wordsInLabelColour() {
    #expect(SessionStatusSeverity.attention.wordsInLabelColour)
    #expect(SessionStatusSeverity.error.wordsInLabelColour)
    #expect(SessionStatusSeverity.active.wordsInLabelColour)
    #expect(!SessionStatusSeverity.normal.wordsInLabelColour)
  }

  @Test(
    "Those words read at 4.5:1 or more, light and dark",
    arguments: [NSAppearance.Name.aqua, .darkAqua])
  @MainActor
  func wordsRead(appearance: NSAppearance.Name) {
    let ratio = contrast(of: .labelColor, in: appearance)
    #expect(ratio >= 4.5, "\(appearance.rawValue): \(String(format: "%.2f", ratio)):1")
  }

  @Test("With Differentiate Without Color, an ended shell is a ring, new output a dot")
  func drawerMarks() {
    #expect(DrawerNewsMark.isRing(.ended, differentiatingWithoutColor: true))
    #expect(!DrawerNewsMark.isRing(.output, differentiatingWithoutColor: true))
    #expect(!DrawerNewsMark.isRing(.ended, differentiatingWithoutColor: false))
  }
}
