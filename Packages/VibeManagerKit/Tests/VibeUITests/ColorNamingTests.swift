import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A colour is read in words, never as its hex code (#232).
@Suite("A colour's name")
struct ColorNamingTests {
  @Test("Common colours get the name a person would give them")
  func names() {
    #expect(ColorNaming.name(ofHex: "#FF3B30") == "red")
    #expect(ColorNaming.name(ofHex: "#0A84FF") == "blue")
    #expect(ColorNaming.name(ofHex: "#AFD5FF") == "light blue")
    #expect(ColorNaming.name(ofHex: "#1C3A5E") == "dark blue")
    #expect(ColorNaming.name(ofHex: "#34C759") == "green")
    #expect(ColorNaming.name(ofHex: "#808080") == "gray")
    #expect(ColorNaming.name(ofHex: "#000000") == "black")
    #expect(ColorNaming.name(ofHex: "#FFFFFF") == "white")
    #expect(ColorNaming.name(ofHex: "not a colour") == nil)
  }

  @Test("Every suggested shade has a name, and none is a hex code")
  func suggestions() {
    for hex in SessionAppearancePalette.suggestedColors.joined() {
      let name = ColorNaming.name(ofHex: hex)
      #expect(name != nil, "\(hex)")
      #expect(name?.contains("#") == false, "\(hex)")
    }
  }
}
