import Foundation

/// The symbols and colours shipped with the application, and the rule that picks one for free.
///
/// The user may change what the pickers offer (#199), in `SessionAppearancePalette`; these lists
/// are what it starts from and what "Default" gives back. Every colour here clears the glyph's
/// contrast with room to spare, and a test holds them to it.
public enum SessionAppearanceCatalog {
  public static let symbolNames = [
    "terminal",
    "wrench.and.screwdriver",
    "doc.text",
    "bolt",
    "ladybug",
    "flask",
    "shippingbox",
    "point.3.connected.trianglepath.dotted",
  ]

  public static let colorHexValues = [
    "#5E5CE6",
    "#0B63E5",
    "#0F7B76",
    "#1E7F4D",
    "#A65B00",
    "#B42318",
    "#7A3DB8",
    "#0A6E8A",
  ]

  /// The words for the shipped colours. Kept out of the stored lists, so that they follow the
  /// language of the application rather than the one they were saved in.
  public static func colorName(of hex: String) -> String? {
    switch SessionAppearancePalette.normalizedHex(hex) {
    case "#5E5CE6":
      String(localized: "Indigo", bundle: .module, comment: "A colour a session may be given.")
    case "#0B63E5":
      String(localized: "Blue", bundle: .module, comment: "A colour a session may be given.")
    case "#0F7B76":
      String(localized: "Teal", bundle: .module, comment: "A colour a session may be given.")
    case "#1E7F4D":
      String(localized: "Green", bundle: .module, comment: "A colour a session may be given.")
    case "#A65B00":
      String(localized: "Amber", bundle: .module, comment: "A colour a session may be given.")
    case "#B42318":
      String(localized: "Red", bundle: .module, comment: "A colour a session may be given.")
    case "#7A3DB8":
      String(localized: "Purple", bundle: .module, comment: "A colour a session may be given.")
    case "#0A6E8A":
      String(
        localized: "Petrol Blue", bundle: .module, comment: "A colour a session may be given.")
    default:
      nil
    }
  }

  /// Worn while the session has no name yet: grey says "not decided" where a colour would claim
  /// a choice the user has not made.
  public static let placeholder = SessionAppearance(symbolName: "terminal", colorHex: "#8E8E96")

  /// The identity a name gets when the user picks nothing, from the shipped lists.
  public static func derived(forName name: String) -> SessionAppearance {
    SessionAppearancePalette.default.derived(forName: name)
  }

  /// The identity a session gets when the user picks nothing, from the shipped lists.
  public static func defaultAppearance(forName name: String, projectIcon: SessionIconID?)
    -> SessionAppearance
  {
    SessionAppearancePalette.default.defaultAppearance(forName: name, projectIcon: projectIcon)
  }

  /// Whether a symbol and a colour can be stored as they are and drawn: a symbol name, and
  /// `#RRGGBB` (or `#RRGGBBAA`) written with its `#`. The one rule for a session and a template, so
  /// that a template found valid never gives a session that cannot be created. Whether the symbol
  /// exists on this Mac is for the interface.
  public static func isWellFormed(_ appearance: SessionAppearance) -> Bool {
    let symbol = appearance.symbolName
    guard !symbol.isEmpty, symbol == symbol.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return false
    }
    let color = appearance.colorHex
    guard color.count == 7 || color.count == 9, color.first == "#" else { return false }
    return color.dropFirst().allSatisfy(\.isHexDigit)
  }
}

/// What the pickers of a session's appearance offer (#199): the shipped lists, or the user's.
///
/// Changing it never touches a session already made: each keeps the symbol and colour it was
/// stored with, offered or not. It changes what a new session is offered, and what a name is given
/// when nothing is picked — the rule picks among the lists as they are now.
public struct SessionAppearancePalette: Hashable, Codable, Sendable {
  /// A colour of the palette, and the word VoiceOver says for it. Without a name, the hex is said.
  public struct Swatch: Hashable, Codable, Sendable, Identifiable {
    /// `#RRGGBB`, upper case.
    public let hex: String
    public let name: String?

    public init(hex: String, name: String? = nil) {
      self.hex = SessionAppearancePalette.normalizedHex(hex) ?? hex
      let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumNameLength)
      self.name = trimmed?.isEmpty == false ? trimmed.map(String.init) : nil
    }

    /// A word or two for VoiceOver, not a description.
    public static let maximumNameLength = 40

    public var id: String { hex }

    /// What VoiceOver and the Settings call it: the name given, else the shipped colour's own.
    /// `nil` for a colour added without a name, which is then said by its hex.
    public var displayName: String? {
      name ?? SessionAppearanceCatalog.colorName(of: hex)
    }
  }

  public private(set) var symbols: [String]
  public private(set) var swatches: [Swatch]

  /// More would make the pickers a wall: they are rows of 26-point choices in a popover.
  public static let maximumCount = 48
  /// The contrast the white glyph needs on a colour: WCAG's 3:1 for graphics that carry meaning.
  public static let minimumGlyphContrast = 3.0

  public static let `default` = SessionAppearancePalette(
    uncheckedSymbols: SessionAppearanceCatalog.symbolNames,
    swatches: SessionAppearanceCatalog.colorHexValues.map { Swatch(hex: $0) }
  )

  private init(uncheckedSymbols: [String], swatches: [Swatch]) {
    symbols = uncheckedSymbols
    self.swatches = swatches
  }

  /// The lists as given, cleaned: blanks, duplicates and malformed colours dropped, the rest cut to
  /// `maximumCount`. A list left empty takes the shipped one back, so a picker never offers nothing.
  public init(symbols: [String], swatches: [Swatch]) {
    var seenSymbols: Set<String> = []
    let symbols = symbols.map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seenSymbols.insert($0).inserted }
    var seenColors: Set<String> = []
    let swatches = swatches.compactMap { swatch in
      Self.normalizedHex(swatch.hex).map { Swatch(hex: $0, name: swatch.name) }
    }.filter { seenColors.insert($0.hex).inserted }
    self.symbols =
      symbols.isEmpty
      ? SessionAppearanceCatalog.symbolNames : Array(symbols.prefix(Self.maximumCount))
    self.swatches =
      swatches.isEmpty
      ? Self.default.swatches : Array(swatches.prefix(Self.maximumCount))
  }

  /// Read field by field: a list that cannot be read is the shipped one, and costs the other nothing.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      symbols: (try? container.decode([String].self, forKey: .symbols)) ?? [],
      swatches: (try? container.decode([Swatch].self, forKey: .swatches)) ?? [])
  }

  /// A list left as shipped is written as nothing: it then follows the application when a later
  /// version ships another, and changing the colours does not freeze the symbols.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if symbols != Self.default.symbols {
      try container.encode(symbols, forKey: .symbols)
    }
    if swatches != Self.default.swatches {
      try container.encode(swatches, forKey: .swatches)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case symbols, swatches
  }

  public var isDefault: Bool { self == .default }

  public var colorHexValues: [String] { swatches.map(\.hex) }

  /// The same lists without the symbols `isKept` refuses — those this Mac cannot draw. The shipped
  /// symbols when none is left, so that a picker always has one to offer.
  public func keepingSymbols(where isKept: (String) -> Bool) -> SessionAppearancePalette {
    SessionAppearancePalette(symbols: symbols.filter(isKept), swatches: swatches)
  }

  // MARK: - Editing

  public var canAddSymbol: Bool { symbols.count < Self.maximumCount }
  public var canAddSwatch: Bool { swatches.count < Self.maximumCount }
  public var canRemoveSymbol: Bool { symbols.count > 1 }
  public var canRemoveSwatch: Bool { swatches.count > 1 }

  public func containsSymbol(_ symbol: String) -> Bool { symbols.contains(symbol) }

  public func containsColor(_ hex: String) -> Bool {
    guard let hex = Self.normalizedHex(hex) else { return false }
    return swatches.contains { $0.hex == hex }
  }

  /// Whether the pickers offer this symbol and this colour.
  public func contains(_ appearance: SessionAppearance) -> Bool {
    containsSymbol(appearance.symbolName) && containsColor(appearance.colorHex)
  }

  /// The symbols a picker shows: the list, then `current` when the list no longer offers it — a
  /// session or a template keeps what it has, and must be able to see it chosen.
  public func symbolChoices(keeping current: String?) -> [String] {
    guard let current, !current.isEmpty, !containsSymbol(current) else { return symbols }
    return symbols + [current]
  }

  /// The colours a picker shows: the list, then `current` when the list no longer offers it.
  public func swatchChoices(keeping current: String?) -> [Swatch] {
    guard let current, let hex = Self.normalizedHex(current), !containsColor(hex) else {
      return swatches
    }
    return swatches + [Swatch(hex: hex)]
  }

  /// Adds a symbol at the end. Refused — `false` — when it is blank, already there or the list full.
  @discardableResult
  public mutating func addSymbol(_ symbol: String) -> Bool {
    let symbol = symbol.trimmingCharacters(in: .whitespaces)
    guard !symbol.isEmpty, canAddSymbol, !symbols.contains(symbol) else { return false }
    symbols.append(symbol)
    return true
  }

  /// Adds a colour at the end. Refused when it is malformed, already there, the list full, or too
  /// pale for the white glyph to be read on it.
  @discardableResult
  public mutating func addSwatch(_ swatch: Swatch) -> Bool {
    guard let hex = Self.normalizedHex(swatch.hex), canAddSwatch, !containsColor(hex),
      Self.isLegible(hex)
    else { return false }
    swatches.append(Swatch(hex: hex, name: swatch.name))
    return true
  }

  /// The shipped symbols back, the colours left as they are.
  public mutating func restoreDefaultSymbols() {
    symbols = Self.default.symbols
  }

  /// The shipped colours back, the symbols left as they are.
  public mutating func restoreDefaultSwatches() {
    swatches = Self.default.swatches
  }

  /// The last one of a list stays: a picker with nothing to offer would have no way back.
  public mutating func removeSymbol(_ symbol: String) {
    guard canRemoveSymbol else { return }
    symbols.removeAll { $0 == symbol }
  }

  public mutating func removeSwatch(_ hex: String) {
    guard canRemoveSwatch, let hex = Self.normalizedHex(hex) else { return }
    swatches.removeAll { $0.hex == hex }
  }

  /// Moves `symbol` by `offset` places, stopping at either end.
  public mutating func moveSymbol(_ symbol: String, by offset: Int) {
    guard let from = symbols.firstIndex(of: symbol) else { return }
    moveSymbol(symbol, to: from + offset)
  }

  /// Puts `symbol` at `index` of the list as it will be once it has been taken out of its place.
  public mutating func moveSymbol(_ symbol: String, to index: Int) {
    guard let from = symbols.firstIndex(of: symbol) else { return }
    let moved = symbols.remove(at: from)
    symbols.insert(moved, at: min(max(index, 0), symbols.count))
  }

  public mutating func moveSwatch(_ hex: String, by offset: Int) {
    guard let hex = Self.normalizedHex(hex),
      let from = swatches.firstIndex(where: { $0.hex == hex })
    else { return }
    moveSwatch(hex, to: from + offset)
  }

  public mutating func moveSwatch(_ hex: String, to index: Int) {
    guard let hex = Self.normalizedHex(hex),
      let from = swatches.firstIndex(where: { $0.hex == hex })
    else { return }
    let moved = swatches.remove(at: from)
    swatches.insert(moved, at: min(max(index, 0), swatches.count))
  }

  // MARK: - The identity of a name

  /// The identity a name gets when the user picks nothing, among the lists as they are.
  ///
  /// Derived rather than random so the preview stays put while typing continues, and so the same
  /// name always looks the same. The hash is written out rather than taken from `Hasher`, whose
  /// seed changes at every launch: an identity that moved between two runs would be worse than
  /// no identity at all.
  public func derived(forName name: String) -> SessionAppearance {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return SessionAppearanceCatalog.placeholder }

    let hash = Self.fnv1a(key)
    let symbol = symbols[Int(hash % UInt64(symbols.count))]
    let color = swatches[Int((hash / UInt64(symbols.count)) % UInt64(swatches.count))]
    return SessionAppearance(symbolName: symbol, colorHex: color.hex)
  }

  /// The identity a session gets when the user picks nothing (#27, #183): the project's icon when
  /// its folder has one, over the symbol and the colour its name gives among the lists as they are
  /// — what the badge falls back on if the icon's file ever goes missing.
  ///
  /// The one rule for a creation and for Revert to Default Icon.
  public func defaultAppearance(forName name: String, projectIcon: SessionIconID?)
    -> SessionAppearance
  {
    var appearance = derived(forName: name)
    appearance.iconID = projectIcon
    return appearance
  }

  private static func fnv1a(_ value: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }

  // MARK: - Colours

  /// `#RRGGBB` upper case, from `RRGGBB`, `#rrggbb` or `#RRGGBBAA` (whose alpha is dropped: a badge
  /// is opaque). `nil` for anything else.
  public static func normalizedHex(_ text: String) -> String? {
    var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else {
      return nil
    }
    return "#" + digits.prefix(6).uppercased()
  }

  /// WCAG's contrast between the white glyph and `hex`, from 1 to 21. `nil` for a malformed colour.
  ///
  /// The badge is the same in light and in dark: a white symbol on its colour. What the window
  /// around it looks like does not change what the symbol is read against.
  public static func glyphContrast(on hex: String) -> Double? {
    guard let luminance = relativeLuminance(hex) else { return nil }
    return 1.05 / (luminance + 0.05)
  }

  public static func isLegible(_ hex: String) -> Bool {
    (glyphContrast(on: hex) ?? 0) >= minimumGlyphContrast
  }

  /// The same hue, darkened just enough for the glyph to be read on it; the colour itself when it
  /// already is. `nil` for a malformed colour.
  public static func legibleVariant(of hex: String) -> String? {
    guard let hex = normalizedHex(hex), let (red, green, blue) = components(hex) else { return nil }
    if isLegible(hex) { return hex }
    // Scaling the three channels keeps the hue; the largest factor that clears the bar, searched
    // by halves, is the lightest colour of that hue the glyph can be read on.
    var low = 0.0
    var high = 1.0
    for _ in 0..<24 {
      let middle = (low + high) / 2
      if isLegible(Self.hex(red * middle, green * middle, blue * middle)) {
        low = middle
      } else {
        high = middle
      }
    }
    return Self.hex(red * low, green * low, blue * low)
  }

  private static func components(_ hex: String) -> (Double, Double, Double)? {
    guard let hex = normalizedHex(hex), let value = UInt32(hex.dropFirst(), radix: 16) else {
      return nil
    }
    return (
      Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
      Double(value & 0xFF) / 255
    )
  }

  /// Rounded down, so that a colour found legible stays legible once written.
  private static func hex(_ red: Double, _ green: Double, _ blue: Double) -> String {
    func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded(.down)) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
  }

  private static func relativeLuminance(_ hex: String) -> Double? {
    guard let (red, green, blue) = components(hex) else { return nil }
    func channel(_ value: Double) -> Double {
      value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }
}
