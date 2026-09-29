import Foundation

/// Why a theme's definition — a file of the library, or an agent's answer — cannot be a theme
/// (#118). The words of `details` are English and precise: they are sent back to the agent as they
/// are, and never shown to the user.
public enum ThemeFileProblem: Error, Hashable, Sendable {
  case tooLarge
  case notJSON
  /// A `format` this version does not read, or none.
  case unknownFormat
  case unknownKey(String)
  case missingKey(String)
  /// A value of the wrong kind or shape: a colour that is not `#RRGGBB`, a font style unknown.
  case invalidValue(String)
  /// Empty, too long, or with characters a name cannot hold.
  case invalidName
  /// Light when a dark theme was asked for, or the other way round.
  case wrongMode(expectedDark: Bool)
  /// Pairs a reader could not read.
  case illegible([ThemeContrastFailure])
  /// A number of the layout outside what it may be.
  case outOfRange(String, ClosedRange<Double>)
  /// A font family neither installed on the Mac nor on Google Fonts.
  case unknownFont(String, family: String)
  /// An address of a picture the user never wrote.
  case inventedImageURL(String)

  /// What kind of problem it is, for the diagnostics, where nothing the file holds is written.
  public enum Code: String, Hashable, Sendable, DiagnosticTokenConvertible {
    case tooLarge, notJSON, unknownFormat, unknownKey, missingKey, invalidValue, invalidName
    case wrongMode, illegible, outOfRange, unknownFont, inventedImageURL
  }

  public var code: Code {
    switch self {
    case .tooLarge: .tooLarge
    case .notJSON: .notJSON
    case .unknownFormat: .unknownFormat
    case .unknownKey: .unknownKey
    case .missingKey: .missingKey
    case .invalidValue: .invalidValue
    case .invalidName: .invalidName
    case .wrongMode: .wrongMode
    case .illegible: .illegible
    case .outOfRange: .outOfRange
    case .unknownFont: .unknownFont
    case .inventedImageURL: .inventedImageURL
    }
  }

  /// What is wrong, one line each, as the agent is told.
  public var details: [String] {
    switch self {
    case .tooLarge:
      ["The answer is larger than \(ConversationThemeFile.maximumSize) bytes."]
    case .notJSON:
      ["The answer is not a JSON object."]
    case .unknownFormat:
      ["\"format\" must be \(ConversationThemeFile.format)."]
    case .unknownKey(let key):
      ["\"\(key)\" is not a key of the schema."]
    case .missingKey(let key):
      ["\"\(key)\" is missing."]
    case .invalidValue(let key):
      ["\"\(key)\" does not have the form the schema gives it."]
    case .invalidName:
      [
        "\"name\" must be 1 to \(ConversationThemeFile.maximumNameLength) characters, on one line."
      ]
    case .wrongMode(let expectedDark):
      [
        "\"isDark\" must be \(expectedDark): a \(expectedDark ? "dark" : "light") theme is asked for."
      ]
    case .illegible(let failures):
      failures.map(\.description)
    case .outOfRange(let key, let range):
      [
        "\"\(key)\" must be a number from \(ConversationThemeFile.number(range.lowerBound)) to "
          + "\(ConversationThemeFile.number(range.upperBound))."
      ]
    case .unknownFont(let key, let family):
      [
        "\"\(key)\": \"\(family)\" is neither a font installed on every Mac nor a family of Google "
          + "Fonts. Give the exact name of a Google Fonts family, or null."
      ]
    case .inventedImageURL(let url):
      [
        "\"backdrop.imageURL\": \"\(url)\" is not an address the user wrote. Only copy an https "
          + "address from the description; to have a picture drawn, describe it in "
          + "\"backdrop.imagePrompt\" and set imageURL to null."
      ]
    }
  }
}

/// A pair of colours below the contrast it needs.
public struct ThemeContrastFailure: Hashable, Sendable, CustomStringConvertible {
  public let rule: String
  public let foreground: ConversationTheme.ColorRole
  public let foregroundHex: String
  public let background: ConversationTheme.ColorRole
  public let backgroundHex: String
  public let ratio: Double
  public let minimum: Double

  public var description: String {
    let ratio = (self.ratio * 100).rounded(.down) / 100
    return
      "\(foreground.rawValue) \(foregroundHex) on \(background.rawValue) \(backgroundHex) is "
      + "\(String(format: "%.2f", ratio)):1, it needs at least \(String(format: "%.1f", minimum)):1."
  }
}

extension ConversationTheme {
  /// Every pair of `legibilityRules` this theme does not pass.
  public var legibilityFailures: [ThemeContrastFailure] {
    Self.legibilityRules.compactMap { rule in
      guard let foreground = self[rule.foreground], let background = self[rule.background] else {
        return nil
      }
      let ratio = foreground.contrast(with: background)
      guard ratio < rule.minimum else { return nil }
      return ThemeContrastFailure(
        rule: rule.name, foreground: rule.foreground, foregroundHex: foreground.hex,
        background: rule.background, backgroundHex: background.hex, ratio: ratio,
        minimum: rule.minimum)
    }
  }
}

/// The file of a personal theme (#118), which is also what an agent answers. Version 3:
///
/// ```json
/// { "format": 2, "name": "…", "isDark": true, "fontStyle": "system",
///   "colors": { "background": "#RRGGBB", …, "bubbleBorder": null },
///   "fonts": { "message": "Inter", "code": null },
///   "layout": { "blockSpacing": 18, …, "blockRadius": 10 },
///   "backdrop": { "image": null, "imageURL": null, "imagePrompt": "blurred pines at dusk",
///                 "veil": 0.8, "blur": 12, "area": "conversation" } }
/// ```
///
/// Versions 1 (colours alone) and 2 (without `backdrop`) are still read: what they lack is the
/// built-in themes'.
///
/// Its identifier is not in it: the library names a theme by its file. Read strictly — every key
/// known, every colour given — then held to the contrasts of every theme: what the agent writes is
/// only ever data, and a theme shown can always be read.
public enum ConversationThemeFile {
  public static let format = 3
  /// The versions this one reads.
  public static let readableFormats: Set<Int> = [1, 2, 3]
  public static let maximumImagePromptLength = 600
  public static let maximumImageURLLength = 2048
  public static let maximumFontNameLength = 64
  public static let maximumNameLength = 40
  /// Far above what a theme weighs (under 2 KiB), far below what could cost anything to read.
  public static let maximumSize = 64 * 1024

  enum Key: String, CaseIterable {
    case format, name, isDark, fontStyle, colors, fonts, layout, backdrop

    /// What a file of `version` must hold.
    static func required(in version: Int) -> [Key] {
      switch version {
      case 1: [.format, .name, .isDark, .fontStyle, .colors]
      case 2: [.format, .name, .isDark, .fontStyle, .colors, .fonts, .layout]
      default: allCases
      }
    }
  }

  enum BackdropKey: String, CaseIterable {
    case image, imageURL, imagePrompt, veil, blur, area
  }

  enum FontKey: String, CaseIterable {
    case message, code
  }

  /// The theme `data` defines, checked whole: its form, then its contrasts. `expectedDark`, when
  /// given, is the mode the theme was asked for.
  public static func theme(
    from data: Data, id: String, expectedDark: Bool? = nil
  ) throws(ThemeFileProblem) -> ConversationTheme {
    let theme = try decode(data, id: id)
    if let expectedDark, theme.isDark != expectedDark {
      throw .wrongMode(expectedDark: expectedDark)
    }
    let failures = theme.legibilityFailures
    guard failures.isEmpty else { throw .illegible(failures) }
    return theme
  }

  /// The theme `data` defines, its form checked, its contrasts not yet.
  public static func decode(_ data: Data, id: String) throws(ThemeFileProblem)
    -> ConversationTheme
  {
    guard data.count <= maximumSize else { throw .tooLarge }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw .notJSON
    }
    for key in object.keys.sorted() where Key(rawValue: key) == nil {
      throw .unknownKey(key)
    }
    guard let number = object[Key.format.rawValue] as? NSNumber, !isBoolean(number),
      let version = readableFormats.first(where: { Double($0) == number.doubleValue })
    else { throw object[Key.format.rawValue] == nil ? .missingKey("format") : .unknownFormat }
    for key in Key.required(in: version) where object[key.rawValue] == nil {
      throw .missingKey(key.rawValue)
    }
    guard let rawName = object[Key.name.rawValue] as? String, let name = sanitizedName(rawName)
    else { throw .invalidName }
    guard let dark = object[Key.isDark.rawValue] as? NSNumber, isBoolean(dark) else {
      throw .invalidValue(Key.isDark.rawValue)
    }
    guard
      let style = (object[Key.fontStyle.rawValue] as? String).flatMap(
        ConversationTheme.FontStyle.init(rawValue:))
    else {
      throw .invalidValue(Key.fontStyle.rawValue)
    }
    guard let values = object[Key.colors.rawValue] as? [String: Any] else {
      throw .invalidValue(Key.colors.rawValue)
    }
    for key in values.keys.sorted() where ConversationTheme.ColorRole(rawValue: key) == nil {
      throw .unknownKey("colors.\(key)")
    }
    var colors: [ConversationTheme.ColorRole: ThemeColor] = [:]
    for role in ConversationTheme.ColorRole.allCases {
      let path = "colors.\(role.rawValue)"
      guard let value = values[role.rawValue] else { throw .missingKey(path) }
      if value is NSNull, role.isOptional { continue }
      guard let hex = value as? String, isStrictHex(hex), let color = ThemeColor(hex: hex) else {
        throw .invalidValue(path)
      }
      colors[role] = color
    }
    guard
      var theme = ConversationTheme(
        id: id, isDark: dark.boolValue, fontStyle: style, personalName: name, colors: colors)
    else { throw .invalidValue(Key.colors.rawValue) }
    if let fonts = object[Key.fonts.rawValue] { theme.fonts = try decodeFonts(fonts) }
    if let layout = object[Key.layout.rawValue] { theme.layout = try decodeLayout(layout) }
    if let backdrop = object[Key.backdrop.rawValue] {
      theme.backdrop = try decodeBackdrop(backdrop)
    }
    return theme
  }

  private static func decodeBackdrop(_ value: Any) throws(ThemeFileProblem)
    -> ConversationTheme.Backdrop
  {
    guard let values = value as? [String: Any] else { throw .invalidValue(Key.backdrop.rawValue) }
    for key in values.keys.sorted() where BackdropKey(rawValue: key) == nil {
      throw .unknownKey("backdrop.\(key)")
    }
    func path(_ key: BackdropKey) -> String { "backdrop.\(key.rawValue)" }
    /// A string or null; `image` alone may be left out: the agent never gives it.
    func text(_ key: BackdropKey) throws(ThemeFileProblem) -> String? {
      guard let value = values[key.rawValue] else {
        if key == .image { return nil }
        throw .missingKey(path(key))
      }
      if value is NSNull { return nil }
      guard let text = value as? String else { throw .invalidValue(path(key)) }
      return text
    }
    func number(_ key: BackdropKey, _ range: ClosedRange<Double>) throws(ThemeFileProblem)
      -> Double
    {
      guard let value = values[key.rawValue] else { throw .missingKey(path(key)) }
      guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite else {
        throw .invalidValue(path(key))
      }
      guard range.contains(number.doubleValue) else { throw .outOfRange(path(key), range) }
      return number.doubleValue
    }
    var backdrop = ConversationTheme.Backdrop()
    if let image = try text(.image) {
      guard isImageName(image) else { throw .invalidValue(path(.image)) }
      backdrop.image = image
    }
    if let address = try text(.imageURL) {
      guard isImageURL(address) else { throw .invalidValue(path(.imageURL)) }
      backdrop.imageURL = address
    }
    if let prompt = try text(.imagePrompt) {
      let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= maximumImagePromptLength,
        trimmed.unicodeScalars.allSatisfy({
          !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        })
      else { throw .invalidValue(path(.imagePrompt)) }
      backdrop.imagePrompt = trimmed
    }
    backdrop.veil = try number(.veil, ConversationTheme.Backdrop.veilRange)
    backdrop.blur = try number(.blur, ConversationTheme.Backdrop.blurRange)
    guard let area = try text(.area).flatMap(ConversationTheme.Backdrop.Area.init(rawValue:)) else {
      throw .invalidValue(path(.area))
    }
    backdrop.area = area
    return backdrop
  }

  /// An address a picture can be fetched from: https, with a host, and nothing that could be a
  /// file of this Mac.
  public static func isImageURL(_ address: String) -> Bool {
    guard address.count <= maximumImageURLLength, let url = URL(string: address),
      url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil
    else { return false }
    return true
  }

  /// The name the library gives a picture: the digest of its bytes and its type.
  public static func isImageName(_ name: String) -> Bool {
    let parts = name.split(separator: ".")
    guard parts.count == 2, ["jpg", "png"].contains(parts[1]), parts[0].count == 64 else {
      return false
    }
    return parts[0].allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
  }

  private static func decodeFonts(_ value: Any) throws(ThemeFileProblem) -> ConversationTheme.Fonts
  {
    guard let values = value as? [String: Any] else { throw .invalidValue(Key.fonts.rawValue) }
    for key in values.keys.sorted() where FontKey(rawValue: key) == nil {
      throw .unknownKey("fonts.\(key)")
    }
    var families: [FontKey: String] = [:]
    for key in FontKey.allCases {
      let path = "fonts.\(key.rawValue)"
      guard let value = values[key.rawValue] else { throw .missingKey(path) }
      if value is NSNull { continue }
      guard let family = value as? String, isFontFamily(family) else { throw .invalidValue(path) }
      families[key] = family
    }
    return ConversationTheme.Fonts(message: families[.message], code: families[.code])
  }

  private static func decodeLayout(_ value: Any) throws(ThemeFileProblem)
    -> ConversationTheme.Layout
  {
    guard let values = value as? [String: Any] else { throw .invalidValue(Key.layout.rawValue) }
    for key in values.keys.sorted() where ConversationTheme.Layout.Key(rawValue: key) == nil {
      throw .unknownKey("layout.\(key)")
    }
    var layout = ConversationTheme.Layout()
    for key in ConversationTheme.Layout.Key.allCases {
      let path = "layout.\(key.rawValue)"
      guard let value = values[key.rawValue] else { throw .missingKey(path) }
      guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite else {
        throw .invalidValue(path)
      }
      guard key.range.contains(number.doubleValue) else { throw .outOfRange(path, key.range) }
      layout[key] = number.doubleValue
    }
    return layout
  }

  /// A family name as Google Fonts and macOS write them: letters, digits, spaces and hyphens.
  /// Nothing else can reach a URL or a folder built from it.
  public static func isFontFamily(_ name: String) -> Bool {
    guard (1...maximumFontNameLength).contains(name.count), name.first != " ", name.last != " "
    else { return false }
    return name.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        || $0 == " " || $0 == "-"
    }
  }

  /// A number as the agent is told it: without a useless fraction.
  static func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  /// The file of `theme`: its keys sorted, so that the same theme is always the same bytes.
  public static func encode(_ theme: ConversationTheme) -> Data {
    var colors: [String: Any] = [:]
    for role in ConversationTheme.ColorRole.allCases {
      colors[role.rawValue] = theme[role]?.hex ?? NSNull()
    }
    let object: [String: Any] = [
      Key.format.rawValue: format,
      Key.name.rawValue: theme.personalName ?? theme.id,
      Key.isDark.rawValue: theme.isDark,
      Key.fontStyle.rawValue: theme.fontStyle.rawValue,
      Key.colors.rawValue: colors,
      Key.fonts.rawValue: [
        FontKey.message.rawValue: theme.fonts.message ?? NSNull(),
        FontKey.code.rawValue: theme.fonts.code ?? NSNull(),
      ] as [String: Any],
      Key.layout.rawValue: Dictionary(
        uniqueKeysWithValues: ConversationTheme.Layout.Key.allCases.map {
          ($0.rawValue, theme.layout[$0])
        }),
      Key.backdrop.rawValue: backdrop(of: theme),
    ]
    // A dictionary of strings, numbers, booleans and nulls always serializes.
    return
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data()
  }

  /// The backdrop as written: `image` only when there is one — an agent is shown the theme, and
  /// never gives that key.
  private static func backdrop(of theme: ConversationTheme) -> [String: Any] {
    var backdrop: [String: Any] = [
      BackdropKey.imageURL.rawValue: theme.backdrop.imageURL ?? NSNull(),
      BackdropKey.imagePrompt.rawValue: theme.backdrop.imagePrompt ?? NSNull(),
      BackdropKey.veil.rawValue: theme.backdrop.veil,
      BackdropKey.blur.rawValue: theme.backdrop.blur,
      BackdropKey.area.rawValue: theme.backdrop.area.rawValue,
    ]
    if let image = theme.backdrop.image { backdrop[BackdropKey.image.rawValue] = image }
    return backdrop
  }

  /// `name` trimmed, or `nil` when it cannot name a theme: empty, too long, or holding a control,
  /// a line break or a character that reorders text around it.
  public static func sanitizedName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumNameLength else { return nil }
    let forbidden = CharacterSet.controlCharacters.union(.newlines).union(
      CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}")
        .union(CharacterSet(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}")))
    guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
    return trimmed
  }

  private static func isStrictHex(_ value: String) -> Bool {
    value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
  }

  private static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }
}
