import AppKit
import SwiftUI
import Testing
import VibeApplication

@testable import VibeUI

/// The words of a state on a session's row are small text: WCAG asks 4.5:1 of them, in light and in
/// dark (#233). Measured against the window's background, which stands for the sidebar's material:
/// the material lets the desktop through, so no colour of its own can be read.
@Suite("The contrast of a session's state in the sidebar")
struct SessionStatusContrastTests {
  enum Appearance: String, CaseIterable, CustomTestStringConvertible {
    case light, dark
    var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    var testDescription: String { rawValue }
  }

  /// The states whose colour is below 4.5:1 today, made legible by #231. Once one passes, its
  /// known issue goes unrecorded and the test fails: take it out of this list.
  static let awaitingFix: Set<String> = [
    "active light", "active dark", "attention light", "error light",
  ]

  @Test(
    "Every state's words read at 4.5:1",
    arguments: [SessionStatusSeverity.normal, .active, .attention, .error], Appearance.allCases)
  func legible(severity: SessionStatusSeverity, appearance: Appearance) {
    let ratio = Self.contrast(of: severity.tint, in: appearance.name)
    let label = "\(severity) \(appearance.rawValue)"
    let check = {
      #expect(ratio >= 4.5, "\(label) is \(String(format: "%.2f", ratio)):1, needs 4.5:1")
    }
    if Self.awaitingFix.contains(label) {
      withKnownIssue("Below 4.5:1 until #231", check)
    } else {
      check()
    }
  }

  /// The colour drawn over the window's background, its opacity included, as the eye gets it.
  private static func contrast(of color: Color, in appearance: NSAppearance.Name) -> Double {
    var ratio = 0.0
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
      guard let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
        let foreground = NSColor(color).usingColorSpace(.sRGB)
      else { return }
      let alpha = foreground.alphaComponent
      func over(_ front: CGFloat, _ back: CGFloat) -> Double {
        Double(front * alpha + back * (1 - alpha))
      }
      let drawn = ThemeColor(
        red: over(foreground.redComponent, background.redComponent),
        green: over(foreground.greenComponent, background.greenComponent),
        blue: over(foreground.blueComponent, background.blueComponent))
      let behind = ThemeColor(
        red: Double(background.redComponent), green: Double(background.greenComponent),
        blue: Double(background.blueComponent))
      ratio = drawn.contrast(with: behind)
    }
    return ratio
  }
}
