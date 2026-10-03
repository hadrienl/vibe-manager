import Foundation
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
    #expect(ColorNaming.name(ofHex: "#1C3A5E") == "very dark blue")
    #expect(ColorNaming.name(ofHex: "#2C6CCC") == "dark blue")
    #expect(ColorNaming.name(ofHex: "#5F38FF") == "indigo")
    #expect(ColorNaming.name(ofHex: "#00FF00") == "green")
    #expect(ColorNaming.name(ofHex: "#E0E0E0") == "light gray")
    #expect(ColorNaming.name(ofHex: "#808080") == "gray")
    #expect(ColorNaming.name(ofHex: "#404040") == "dark gray")
    // A pure hue is said by its own name, not its neighbour's.
    #expect(ColorNaming.name(ofHex: "#0000FF") == "blue")
    #expect(ColorNaming.name(ofHex: "#FFFF00") == "yellow")
    #expect(ColorNaming.name(ofHex: "#000000") == "black")
    #expect(ColorNaming.name(ofHex: "#FFFFFF") == "white")
    #expect(ColorNaming.name(ofHex: "not a colour") == nil)
  }

  @Test("Every suggested shade has a name, none a hex code, and few the same name")
  func suggestions() {
    for hex in SessionAppearancePalette.suggestedColors.joined() {
      let name = ColorNaming.name(ofHex: hex)
      #expect(name != nil, "\(hex)")
      #expect(name?.contains("#") == false, "\(hex)")
    }
    let names = SessionAppearancePalette.suggestedColors.joined().compactMap(
      ColorNaming.name(ofHex:))
    // Names stay true rather than all different: the grid's depths overlap from one hue to the
    // next, and ten names repeat.
    #expect(names.count - Set(names).count <= 10, "\(names)")
    #expect(names.filter { $0.hasPrefix("very dark") }.count <= 5, "\(names)")
  }

  @Test("Every name a colour can get is translated into French")
  func everyNameTranslated() throws {
    let catalog = try JSONSerialization.jsonObject(
      with: Data(contentsOf: Self.sourceCatalog)) as? [String: Any]
    let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
    func french(_ key: String) -> String? {
      let localizations = strings[key]?["localizations"] as? [String: Any]
      let unit = (localizations?["fr"] as? [String: Any])?["stringUnit"] as? [String: Any]
      return unit?["value"] as? String
    }
    var names: Set<String> = []
    for hue in stride(from: 0.0, to: 360, by: 1) {
      for brightness in stride(from: 0.0, through: 1, by: 0.05) {
        for saturation in [0.0, 0.1, 0.3, 0.9] {
          names.insert(ColorNaming.name(hue: hue, saturation: saturation, brightness: brightness))
        }
      }
    }
    for name in names {
      var base = name
      var format: String?
      for prefix in ["very dark ", "dark ", "light "] where name.hasPrefix(prefix) {
        base = String(name.dropFirst(prefix.count))
        format = prefix + "%@"
        break
      }
      #expect(french(base) != nil, "\(base) has no French")
      if let format { #expect(french(format) != nil, "\(format) has no French") }
    }
  }

  /// VibeUI's catalog, read from the sources: the built bundle holds compiled strings.
  private static var sourceCatalog: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/VibeUI/Localizable.xcstrings")
  }
}
