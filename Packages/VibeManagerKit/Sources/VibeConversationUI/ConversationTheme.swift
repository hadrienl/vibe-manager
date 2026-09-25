import SwiftUI
import VibeApplication

/// A colour of a theme, as written in its definition: `#RRGGBB`.
public struct ThemeColor: Hashable, Sendable, ExpressibleByStringLiteral {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let opacity: Double

  public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  public init(stringLiteral hex: String) {
    self = ThemeColor(hex: hex) ?? ThemeColor(red: 1, green: 0, blue: 1)
  }

  public init?(hex: String) {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    red = Double((value >> 16) & 0xFF) / 255
    green = Double((value >> 8) & 0xFF) / 255
    blue = Double(value & 0xFF) / 255
    opacity = 1
  }

  public var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
  }

  /// WCAG's relative luminance.
  public var luminance: Double {
    func channel(_ value: Double) -> Double {
      value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }

  /// WCAG's contrast ratio, from 1 to 21.
  public func contrast(with other: ThemeColor) -> Double {
    let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
    return (lighter + 0.05) / (darker + 0.05)
  }
}

/// Every colour and font the conversation view draws with (#38). No view of the module uses a
/// colour of its own: it reads the theme from the environment.
public struct ConversationTheme: Hashable, Sendable, Identifiable {
  public enum FontStyle: String, Hashable, Sendable {
    case system, serif, monospaced
  }

  public let id: String
  public let isDark: Bool
  public var fontStyle: FontStyle
  /// A font family chosen by the user, in place of the theme's.
  public var messageFontFamily: String?
  public var codeFontFamily: String?

  public var background: ThemeColor
  public var surface: ThemeColor
  public var raised: ThemeColor
  public var text: ThemeColor
  public var secondaryText: ThemeColor
  public var border: ThemeColor
  public var accent: ThemeColor
  public var onAccent: ThemeColor
  public var bubble: ThemeColor
  public var bubbleText: ThemeColor
  /// Drawn around the bubble: only where the bubble and the background are too close to tell apart.
  public var bubbleBorder: ThemeColor?
  public var codeBackground: ThemeColor
  public var codeText: ThemeColor
  public var keyword: ThemeColor
  public var string: ThemeColor
  public var comment: ThemeColor
  public var number: ThemeColor
  public var type: ThemeColor
  public var function: ThemeColor
  public var addedBackground: ThemeColor
  public var addedText: ThemeColor
  public var removedBackground: ThemeColor
  public var removedText: ThemeColor
  public var success: ThemeColor
  public var failure: ThemeColor
  public var warning: ThemeColor
  public var warningBackground: ThemeColor

  public var colorScheme: ColorScheme { isDark ? .dark : .light }

  /// The pairs a reader must be able to read, with the ratio each needs: text 4.5:1, state
  /// symbols and large text 3:1. Pinned by a test for every theme.
  public var legibilityPairs:
    [(name: String, foreground: ThemeColor, background: ThemeColor, minimum: Double)]
  {
    [
      ("text", text, background, 4.5),
      ("secondaryText", secondaryText, background, 4.5),
      ("textOnSurface", text, surface, 4.5),
      ("secondaryOnSurface", secondaryText, surface, 4.5),
      ("bubbleText", bubbleText, bubble, 4.5),
      ("codeText", codeText, codeBackground, 4.5),
      ("keyword", keyword, codeBackground, 4.5),
      ("string", string, codeBackground, 4.5),
      ("comment", comment, codeBackground, 4.5),
      ("number", number, codeBackground, 4.5),
      ("type", type, codeBackground, 4.5),
      ("function", function, codeBackground, 4.5),
      ("addedText", addedText, addedBackground, 4.5),
      ("removedText", removedText, removedBackground, 4.5),
      ("onAccent", onAccent, accent, 4.5),
      ("success", success, surface, 3),
      ("failure", failure, surface, 3),
      ("warning", warning, surface, 3),
      ("warningOnBanner", text, warningBackground, 4.5),
      ("accent", accent, background, 3),
    ]
  }

  public func messageFont(size: Double) -> Font {
    if let family = messageFontFamily { return .custom(family, size: size) }
    switch fontStyle {
    case .system: return .system(size: size)
    case .serif: return .system(size: size, design: .serif)
    case .monospaced: return .system(size: size, design: .monospaced)
    }
  }

  public func codeFont(size: Double) -> Font {
    codeFontFamily.map { .custom($0, size: size) } ?? .system(size: size, design: .monospaced)
  }

  /// Interface text — titles of tool calls, the composer's hints. Monospaced in the Terminal theme,
  /// the system's everywhere else.
  public func interfaceFont(size: Double, weight: Font.Weight = .regular) -> Font {
    fontStyle == .monospaced
      ? .system(size: size, weight: weight, design: .monospaced)
      : .system(size: size, weight: weight)
  }

  /// The theme with the user's accent and fonts applied.
  public func applying(_ appearance: ConversationAppearance) -> ConversationTheme {
    var theme = self
    if let accent = Self.accentColors[appearance.accent] {
      theme.accent = isDark ? accent.dark : accent.light
      theme.onAccent = isDark ? "#0B1420" : "#FFFFFF"
    }
    // The system's own families are reached by their design: SwiftUI does not know them by name.
    switch appearance.messageFont {
    case "SF Pro": theme.fontStyle = .system
    case "New York": theme.fontStyle = .serif
    case let family: theme.messageFontFamily = family
    }
    theme.codeFontFamily = appearance.codeFont == "SF Mono" ? nil : appearance.codeFont
    return theme
  }

  static let accentColors: [ConversationAppearance.Accent: (light: ThemeColor, dark: ThemeColor)] =
    [
      .blue: ("#0A62D0", "#4D9BFF"),
      .purple: ("#6B43C6", "#B69CFF"),
      .pink: ("#B4336C", "#FF8DBE"),
      .orange: ("#A84A0A", "#FFA25C"),
      .green: ("#1A7A3F", "#5BD17A"),
      .graphite: ("#55565E", "#B8B9C2"),
    ]
}

extension ConversationTheme {
  public static let systemLight = ConversationTheme(
    id: "system-light", isDark: false, fontStyle: .system,
    background: "#FFFFFF", surface: "#F7F7F6", raised: "#FFFFFF", text: "#1D1D1F",
    secondaryText: "#5F5F66", border: "#E2E2E0", accent: "#0A62D0", onAccent: "#FFFFFF",
    bubble: "#E6EEFB", bubbleText: "#10243F", codeBackground: "#F4F4F3", codeText: "#24292F",
    keyword: "#A0217F", string: "#B3261E", comment: "#636A73", number: "#1C3FB8",
    type: "#1F6A7A", function: "#6B3FA0", addedBackground: "#E6F4EA", addedText: "#17722F",
    removedBackground: "#FDECEC", removedText: "#B42318", success: "#1A7F37", failure: "#C62828",
    warning: "#A15C00", warningBackground: "#FFF4E0")

  public static let systemDark = ConversationTheme(
    id: "system-dark", isDark: true, fontStyle: .system,
    background: "#1E1E20", surface: "#27272A", raised: "#2C2C2F", text: "#EDEDEF",
    secondaryText: "#A0A0A8", border: "#3A3A3E", accent: "#4D9BFF", onAccent: "#0B1420",
    bubble: "#1F3354", bubbleText: "#E4EEFF", codeBackground: "#161618", codeText: "#E1E4E8",
    keyword: "#FF7AB2", string: "#FF8170", comment: "#8A96A3", number: "#D9C97C",
    type: "#6BDFFF", function: "#B281EB", addedBackground: "#15301F", addedText: "#6FDD8B",
    removedBackground: "#3A1C1C", removedText: "#FF8A80", success: "#5BD17A", failure: "#FF6B6B",
    warning: "#F5A524", warningBackground: "#3A2A10")

  public static let paper = ConversationTheme(
    id: "paper", isDark: false, fontStyle: .serif,
    background: "#FAF7F0", surface: "#F4EFE4", raised: "#FFFDF8", text: "#2B2620",
    secondaryText: "#665C50", border: "#E3DACA", accent: "#A6461A", onAccent: "#FFFFFF",
    bubble: "#EFE3D0", bubbleText: "#3A2A18", codeBackground: "#F1EADC", codeText: "#3B342B",
    keyword: "#8E3B6B", string: "#566410", comment: "#6E6356", number: "#A13F14",
    type: "#2F6173", function: "#6B4E16", addedBackground: "#E8EFD8", addedText: "#40570F",
    removedBackground: "#F6DFD6", removedText: "#9C2F14", success: "#476117", failure: "#B3261E",
    warning: "#9A5B00", warningBackground: "#F6E7C8")

  public static let night = ConversationTheme(
    id: "night", isDark: true, fontStyle: .system,
    background: "#14161F", surface: "#1C1F2B", raised: "#20242F", text: "#D8DCEB",
    secondaryText: "#8F96B0", border: "#2A2F40", accent: "#8AA8FF", onAccent: "#10131C",
    bubble: "#262C44", bubbleText: "#DDE3FF", codeBackground: "#10121A", codeText: "#C9D1EE",
    keyword: "#C49BFF", string: "#9ECE6A", comment: "#7780A3", number: "#FF9E64",
    type: "#7DCFFF", function: "#7AA2F7", addedBackground: "#16291E", addedText: "#9ECE6A",
    removedBackground: "#33171D", removedText: "#FF8AA0", success: "#9ECE6A", failure: "#FF7A93",
    warning: "#E0AF68", warningBackground: "#2F2616")

  public static let terminal = ConversationTheme(
    id: "terminal", isDark: true, fontStyle: .monospaced,
    background: "#0B0E0B", surface: "#121712", raised: "#151B15", text: "#CFE8CC",
    secondaryText: "#8AAB86", border: "#243024", accent: "#6BDD6B", onAccent: "#061006",
    bubble: "#172417", bubbleText: "#DDF5D9", codeBackground: "#070907", codeText: "#CFE8CC",
    keyword: "#8BE9FD", string: "#F1FA8C", comment: "#7A9A76", number: "#FFB86C",
    type: "#BD93F9", function: "#50FA7B", addedBackground: "#10260F", addedText: "#7CF07C",
    removedBackground: "#2A1010", removedText: "#FF8B8B", success: "#6BDD6B", failure: "#FF6E6E",
    warning: "#FFC66D", warningBackground: "#2A2410")

  public static let highContrast = ConversationTheme(
    id: "high-contrast", isDark: false, fontStyle: .system,
    background: "#FFFFFF", surface: "#FFFFFF", raised: "#FFFFFF", text: "#000000",
    secondaryText: "#2B2B2B", border: "#000000", accent: "#0033CC", onAccent: "#FFFFFF",
    bubble: "#FFFFFF", bubbleText: "#000000", bubbleBorder: "#000000",
    codeBackground: "#F0F0F0", codeText: "#000000", keyword: "#7A0070", string: "#8A0000",
    comment: "#3D3D3D", number: "#0033CC", type: "#004F5E", function: "#4B0082",
    addedBackground: "#D8F5DD", addedText: "#00561B", removedBackground: "#FBDADA",
    removedText: "#8A0000", success: "#00561B", failure: "#B00000", warning: "#7A4000",
    warningBackground: "#FFE9B8")

  /// The themes offered, in the order the settings show them.
  public static let builtIn: [ConversationTheme] = [
    .systemLight, .systemDark, .paper, .night, .terminal, .highContrast,
  ]

  public static func named(_ identifier: String) -> ConversationTheme? {
    builtIn.first { $0.id == identifier }
  }

  /// The theme in force: the user's choice for the current appearance, Contrast High when macOS
  /// asks for more contrast and the user kept the system's themes.
  public static func resolve(
    _ appearance: ConversationAppearance, isDark: Bool, increasedContrast: Bool
  ) -> ConversationTheme {
    let identifier = appearance.themeIdentifier(isDark: isDark)
    let keptSystemThemes =
      identifier == ConversationAppearance.defaultLightTheme
      || identifier == ConversationAppearance.defaultDarkTheme
    let base: ConversationTheme
    if increasedContrast, keptSystemThemes, !isDark {
      base = .highContrast
    } else {
      base = named(identifier) ?? (isDark ? .systemDark : .systemLight)
    }
    return base.applying(appearance)
  }

  public var localizedName: LocalizedStringResource {
    switch id {
    case "system-light": return LocalizedStringResource("System Light", bundle: .module)
    case "system-dark": return LocalizedStringResource("System Dark", bundle: .module)
    case "paper": return LocalizedStringResource("Paper", bundle: .module)
    case "night": return LocalizedStringResource("Night", bundle: .module)
    case "terminal":
      return LocalizedStringResource(
        "theme.terminal", defaultValue: "Terminal", bundle: .module,
        comment: "The name of a theme that looks like a terminal.")
    default: return LocalizedStringResource("High Contrast", bundle: .module)
    }
  }
}

extension ConversationTheme {
  init(
    id: String, isDark: Bool, fontStyle: FontStyle,
    background: ThemeColor, surface: ThemeColor, raised: ThemeColor, text: ThemeColor,
    secondaryText: ThemeColor, border: ThemeColor, accent: ThemeColor, onAccent: ThemeColor,
    bubble: ThemeColor, bubbleText: ThemeColor, bubbleBorder: ThemeColor? = nil,
    codeBackground: ThemeColor, codeText: ThemeColor,
    keyword: ThemeColor, string: ThemeColor, comment: ThemeColor, number: ThemeColor,
    type: ThemeColor, function: ThemeColor, addedBackground: ThemeColor, addedText: ThemeColor,
    removedBackground: ThemeColor, removedText: ThemeColor, success: ThemeColor,
    failure: ThemeColor, warning: ThemeColor, warningBackground: ThemeColor
  ) {
    self.id = id
    self.isDark = isDark
    self.fontStyle = fontStyle
    self.background = background
    self.surface = surface
    self.raised = raised
    self.text = text
    self.secondaryText = secondaryText
    self.border = border
    self.accent = accent
    self.onAccent = onAccent
    self.bubble = bubble
    self.bubbleText = bubbleText
    self.bubbleBorder = bubbleBorder
    self.codeBackground = codeBackground
    self.codeText = codeText
    self.keyword = keyword
    self.string = string
    self.comment = comment
    self.number = number
    self.type = type
    self.function = function
    self.addedBackground = addedBackground
    self.addedText = addedText
    self.removedBackground = removedBackground
    self.removedText = removedText
    self.success = success
    self.failure = failure
    self.warning = warning
    self.warningBackground = warningBackground
  }
}

private struct ConversationThemeKey: EnvironmentKey {
  static let defaultValue = ConversationTheme.systemLight
}

private struct ConversationAppearanceKey: EnvironmentKey {
  static let defaultValue = ConversationAppearance()
}

extension EnvironmentValues {
  public var conversationTheme: ConversationTheme {
    get { self[ConversationThemeKey.self] }
    set { self[ConversationThemeKey.self] = newValue }
  }

  public var conversationAppearance: ConversationAppearance {
    get { self[ConversationAppearanceKey.self] }
    set { self[ConversationAppearanceKey.self] = newValue }
  }
}
