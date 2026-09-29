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

  /// A short code for the diagnostics, where nothing the file holds is written.
  public var code: String {
    switch self {
    case .tooLarge: "tooLarge"
    case .notJSON: "notJSON"
    case .unknownFormat: "unknownFormat"
    case .unknownKey: "unknownKey"
    case .missingKey: "missingKey"
    case .invalidValue: "invalidValue"
    case .invalidName: "invalidName"
    case .wrongMode: "wrongMode"
    case .illegible: "illegible"
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

/// The file of a personal theme, version 1 (#118), which is also what an agent answers:
///
/// ```json
/// { "format": 1, "name": "…", "isDark": true, "fontStyle": "system",
///   "colors": { "background": "#RRGGBB", …, "bubbleBorder": null } }
/// ```
///
/// Its identifier is not in it: the library names a theme by its file. Read strictly — every key
/// known, every colour given — then held to the contrasts of every theme: what the agent writes is
/// only ever data, and a theme shown can always be read.
public enum ConversationThemeFile {
  public static let format = 1
  public static let maximumNameLength = 40
  /// Far above what a theme weighs (under 2 KiB), far below what could cost anything to read.
  public static let maximumSize = 64 * 1024

  enum Key: String, CaseIterable {
    case format, name, isDark, fontStyle, colors
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
    for key in Key.allCases where object[key.rawValue] == nil {
      throw .missingKey(key.rawValue)
    }
    guard let version = object[Key.format.rawValue] as? NSNumber, !isBoolean(version),
      version.doubleValue == Double(format)
    else { throw .unknownFormat }
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
      let theme = ConversationTheme(
        id: id, isDark: dark.boolValue, fontStyle: style, personalName: name, colors: colors)
    else { throw .invalidValue(Key.colors.rawValue) }
    return theme
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
    ]
    // A dictionary of strings, numbers, booleans and nulls always serializes.
    return
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data()
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
