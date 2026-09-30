import Foundation
import Testing

@testable import VibeDomain

@Suite("The symbols and colours the pickers offer")
struct SessionAppearancePaletteTests {
  private typealias Swatch = SessionAppearancePalette.Swatch

  @Test("Every shipped colour carries the white symbol legibly")
  func shippedColoursAreLegible() {
    for hex in SessionAppearanceCatalog.colorHexValues {
      #expect(SessionAppearancePalette.isLegible(hex), "\(hex)")
    }
    #expect(SessionAppearancePalette.default.isDefault)
  }

  @Test("Contrast is WCAG's, white on the colour")
  func glyphContrast() throws {
    #expect(try #require(SessionAppearancePalette.glyphContrast(on: "#000000")) > 20.9)
    #expect(try #require(SessionAppearancePalette.glyphContrast(on: "#FFFFFF")) == 1)
    #expect(SessionAppearancePalette.glyphContrast(on: "blue") == nil)
    #expect(!SessionAppearancePalette.isLegible("#FFD60A"))
  }

  @Test("A colour too pale is refused; the variant suggested keeps its hue and can be read")
  func paleColourRefusedWithSuggestion() throws {
    var palette = SessionAppearancePalette.default
    let added1 = palette.addSwatch(Swatch(hex: "#FFD60A"))
    #expect(!added1)
    #expect(!palette.containsColor("#FFD60A"))

    let suggestion = try #require(SessionAppearancePalette.legibleVariant(of: "#FFD60A"))
    #expect(SessionAppearancePalette.isLegible(suggestion))
    #expect(suggestion != "#000000")
    // Darkened, not shifted: red stays above green, green far above blue.
    let value = try #require(UInt32(suggestion.dropFirst(), radix: 16))
    let (red, green, blue) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    #expect(red >= green && green > blue)
    let added2 = palette.addSwatch(Swatch(hex: suggestion, name: "Mustard"))
    #expect(added2)
    #expect(palette.swatches.last == Swatch(hex: suggestion, name: "Mustard"))
    #expect(SessionAppearancePalette.legibleVariant(of: "#0B63E5") == "#0B63E5")
  }

  @Test("Colours are written #RRGGBB upper case; a duplicate, however written, is refused")
  func normalization() {
    #expect(SessionAppearancePalette.normalizedHex("0b63e5") == "#0B63E5")
    #expect(SessionAppearancePalette.normalizedHex("#0b63e5ff") == "#0B63E5")
    #expect(SessionAppearancePalette.normalizedHex("#0b63e") == nil)
    var palette = SessionAppearancePalette.default
    let added3 = palette.addSwatch(Swatch(hex: "0b63e5"))
    #expect(!added3)
    #expect(palette.swatches.count == SessionAppearanceCatalog.colorHexValues.count)
  }

  @Test("Symbols are added once, and never blank")
  func addSymbol() {
    var palette = SessionAppearancePalette.default
    let added4 = palette.addSymbol(" star ")
    #expect(added4)
    #expect(palette.symbols.last == "star")
    let added5 = palette.addSymbol("star")
    #expect(!added5)
    let added6 = palette.addSymbol("  ")
    #expect(!added6)
  }

  @Test("The last symbol and the last colour cannot be removed")
  func lastOneStays() {
    var palette = SessionAppearancePalette.default
    for symbol in palette.symbols { palette.removeSymbol(symbol) }
    for swatch in palette.swatches { palette.removeSwatch(swatch.hex) }
    #expect(palette.symbols.count == 1)
    #expect(palette.swatches.count == 1)
    #expect(!palette.canRemoveSymbol && !palette.canRemoveSwatch)
  }

  @Test("A list stops at its maximum")
  func maximum() {
    var palette = SessionAppearancePalette.default
    var index = 0
    while palette.canAddSymbol {
      let added7 = palette.addSymbol("symbol.\(index)")
      #expect(added7)
      index += 1
    }
    #expect(palette.symbols.count == SessionAppearancePalette.maximumCount)
    let added8 = palette.addSymbol("one.more")
    #expect(!added8)
  }

  @Test("Moving a symbol or a colour puts it where it was dropped, and stops at the ends")
  func moving() {
    var palette = SessionAppearancePalette.default
    palette.moveSymbol("bolt", to: 0)
    #expect(palette.symbols.first == "bolt")
    palette.moveSymbol("bolt", by: -1)
    #expect(palette.symbols.first == "bolt")
    palette.moveSymbol("bolt", by: 1)
    #expect(palette.symbols[1] == "bolt")
    palette.moveSwatch("#0a6e8a", to: 0)
    #expect(palette.swatches.first?.hex == "#0A6E8A")
    palette.moveSwatch("#0A6E8A", by: 100)
    #expect(palette.swatches.last?.hex == "#0A6E8A")
  }

  @Test("Restoring one list leaves the other as it is")
  func restoreOneList() {
    var palette = SessionAppearancePalette.default
    palette.addSymbol("star")
    palette.removeSwatch("#B42318")
    palette.restoreDefaultSymbols()
    #expect(palette.symbols == SessionAppearanceCatalog.symbolNames)
    #expect(!palette.containsColor("#B42318"))
    palette.restoreDefaultSwatches()
    #expect(palette.isDefault)
  }

  @Test("A name's identity is taken from the lists as they are, and stays put for the same lists")
  func derivedFromCurrentLists() {
    var palette = SessionAppearancePalette(
      symbols: ["star"], swatches: [Swatch(hex: "#123456")])
    let appearance = palette.derived(forName: "Refactor the webhook")
    #expect(appearance == SessionAppearance(symbolName: "star", colorHex: "#123456"))
    #expect(palette.derived(forName: "  ") == SessionAppearanceCatalog.placeholder)

    palette = .default
    #expect(
      palette.derived(forName: "Refactor the webhook")
        == SessionAppearanceCatalog.derived(forName: "refactor the WEBHOOK"))
  }

  @Test("A draft takes its free identity from its palette")
  func draftUsesItsPalette() {
    let palette = SessionAppearancePalette(symbols: ["star"], swatches: [Swatch(hex: "#123456")])
    let draft = SessionDraft(name: "Anything", palette: palette)
    #expect(draft.effectiveAppearance.symbolName == "star")
    #expect(draft.effectiveAppearance.colorHex == "#123456")
  }

  @Test("A choice no longer offered is shown after the list, once")
  func offListChoices() {
    let palette = SessionAppearancePalette.default
    #expect(palette.symbolChoices(keeping: "bolt") == palette.symbols)
    #expect(palette.symbolChoices(keeping: "star") == palette.symbols + ["star"])
    #expect(palette.swatchChoices(keeping: "#0b63e5") == palette.swatches)
    #expect(palette.swatchChoices(keeping: "#123456").last == Swatch(hex: "#123456"))
    #expect(palette.swatchChoices(keeping: nil) == palette.swatches)
  }

  @Test("Lists read from a file are cleaned; one left empty is the shipped one")
  func decodingCleans() throws {
    let json = Data(
      """
      {"symbols": ["star", "star", " ", "bolt"],
       "swatches": [{"hex": "#123456", "name": " Navy "}, {"hex": "nope"}, {"hex": "123456"}]}
      """.utf8)
    let palette = try JSONDecoder().decode(SessionAppearancePalette.self, from: json)
    #expect(palette.symbols == ["star", "bolt"])
    #expect(palette.swatches == [Swatch(hex: "#123456", name: "Navy")])

    let empty = try JSONDecoder().decode(
      SessionAppearancePalette.self, from: Data(#"{"symbols": [], "swatches": 3}"#.utf8))
    #expect(empty.isDefault)
  }

  @Test("A well-formed appearance is a symbol name and a hex colour, offered or not")
  func wellFormed() {
    #expect(
      SessionAppearanceCatalog.isWellFormed(
        SessionAppearance(symbolName: "star", colorHex: "#123456")))
    #expect(
      !SessionAppearanceCatalog.isWellFormed(SessionAppearance(symbolName: "", colorHex: "#123456"))
    )
    #expect(
      !SessionAppearanceCatalog.isWellFormed(SessionAppearance(symbolName: "star", colorHex: "red"))
    )
  }

  @Test("With the shipped lists, a name looks exactly as it did before the lists could change")
  func shippedIdentityIsPinned() {
    #expect(
      SessionAppearancePalette.default.derived(forName: "Refactor the webhook")
        == SessionAppearance(symbolName: "wrench.and.screwdriver", colorHex: "#0A6E8A"))
    #expect(
      SessionAppearancePalette.default.derived(forName: "Write the release notes")
        == SessionAppearance(
          symbolName: "point.3.connected.trianglepath.dotted", colorHex: "#B42318"))
    #expect(
      SessionAppearancePalette.default.derived(forName: "Fix the login")
        == SessionAppearance(symbolName: "shippingbox", colorHex: "#1E7F4D"))
  }

  @Test("The default appearance puts the project's icon over what the lists give the name")
  func defaultAppearanceFollowsThePalette() throws {
    let palette = SessionAppearancePalette(
      symbols: ["star"], swatches: [.init(hex: "#0B63E5")])
    let icon = try #require(SessionIconID(sha256: String(repeating: "a", count: 64)))
    let appearance = palette.defaultAppearance(forName: "Fix the login", projectIcon: icon)
    #expect(appearance.symbolName == "star")
    #expect(appearance.colorHex == "#0B63E5")
    #expect(appearance.iconID == icon)
  }

  @Test("A list left as shipped is written as nothing, and read back as the shipped one")
  func eachListIsStoredOnItsOwn() throws {
    var palette = SessionAppearancePalette.default
    palette.addSymbol("star")
    let data = try JSONEncoder().encode(palette)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["symbols"] != nil)
    #expect(object["swatches"] == nil)
    #expect(try JSONDecoder().decode(SessionAppearancePalette.self, from: data) == palette)

    let empty = try JSONDecoder().decode(SessionAppearancePalette.self, from: Data("{}".utf8))
    #expect(empty == .default)
  }

  @Test("The shipped colours have names; one added keeps the name it was given, cut to 40")
  func colourNames() {
    for hex in SessionAppearanceCatalog.colorHexValues {
      #expect(SessionAppearanceCatalog.colorName(of: hex) != nil, "\(hex)")
    }
    #expect(SessionAppearancePalette.Swatch(hex: "#5e5ce6").displayName != nil)
    #expect(SessionAppearancePalette.Swatch(hex: "#BB8D14").displayName == nil)
    #expect(
      SessionAppearancePalette.Swatch(hex: "#BB8D14", name: " Mustard ").displayName == "Mustard")
    let long = SessionAppearancePalette.Swatch(
      hex: "#BB8D14", name: String(repeating: "a", count: 60))
    #expect(long.name?.count == SessionAppearancePalette.Swatch.maximumNameLength)
  }
}
