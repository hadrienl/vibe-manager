import AppKit
import SwiftUI
import VibeApplication

/// The theme's colours and fonts as SwiftUI draws them. What a theme is — its colours, its rules,
/// the built-in ones — lives in `VibeApplication`, where it is checked without a view (#118).
extension ThemeColor {
  /// A colour of the interface, in sRGB.
  public init?(_ color: Color) {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    self.init(
      red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
      blue: Double(srgb.blueComponent))
  }

  public var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
  }
}

extension ConversationTheme {
  public var colorScheme: ColorScheme { isDark ? .dark : .light }

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

  /// The name the settings show: the user's own for a theme of theirs, the localized one else.
  public var displayName: String {
    personalName ?? String(localized: localizedName)
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
