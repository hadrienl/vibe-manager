import Foundation

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
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit),
      let value = UInt32(digits, radix: 16)
    else { return nil }
    red = Double((value >> 16) & 0xFF) / 255
    green = Double((value >> 8) & 0xFF) / 255
    blue = Double(value & 0xFF) / 255
    opacity = 1
  }

  /// The colour as `#RRGGBB`, the form a theme and the settings keep it in.
  public var hex: String {
    func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
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
///
/// Six are built in; the others are the user's own (#118), kept one file each, drawn and checked
/// the same way.
public struct ConversationTheme: Hashable, Sendable, Identifiable {
  public enum FontStyle: String, Hashable, Sendable, CaseIterable {
    case system, serif, monospaced
  }

  /// The colours of a theme, by the name its file and its schema give them.
  public enum ColorRole: String, Hashable, Sendable, CaseIterable {
    case background, surface, raised, text, secondaryText, border, accent, onAccent, bubble
    case bubbleText, bubbleBorder, codeBackground, codeText, keyword, string, comment, number
    case type, function, addedBackground, addedText, removedBackground, removedText, success
    case failure, warning, warningBackground

    /// The only colour a theme may go without.
    public var isOptional: Bool { self == .bubbleBorder }
  }

  /// A pair a reader must be able to read, and the ratio it needs.
  public struct LegibilityRule: Hashable, Sendable {
    public let name: String
    public let foreground: ColorRole
    public let background: ColorRole
    public let minimum: Double
  }

  /// The prefix of every personal theme's identifier: none of the built-in ones has it.
  public static let personalPrefix = "personal-"

  public let id: String
  public let isDark: Bool
  /// The name the user gave a theme of their own; `nil` for a built-in one, whose name is
  /// localized.
  public var personalName: String?
  public var fontStyle: FontStyle
  /// The family the messages and the code are drawn with, once the user's choices are applied:
  /// the user's, or else the theme's own (`fonts`).
  public var messageFontFamily: String?
  public var codeFontFamily: String?
  /// The families the theme itself asks for (#118): installed, or fetched from Google Fonts.
  public var fonts = Fonts()
  /// Its spaces, widths and corners (#118).
  public var layout = Layout()
  /// A picture behind the conversation, under a veil of `background` (#118).
  public var backdrop = Backdrop()

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

  public var isPersonal: Bool { id.hasPrefix(Self.personalPrefix) }

  /// The families a theme asks for; `nil` keeps the system's family of its `fontStyle`.
  public struct Fonts: Hashable, Sendable {
    public var message: String?
    public var code: String?

    public init(message: String? = nil, code: String? = nil) {
      self.message = message
      self.code = code
    }
  }

  /// A picture behind the conversation: fetched from an address the user gave, or drawn by an
  /// agent, then kept beside the themes. How much it shows, and where, is the theme's to say.
  public struct Backdrop: Hashable, Sendable {
    public enum Area: String, Hashable, Sendable, CaseIterable {
      /// Behind the messages and the composer.
      case conversation
      /// Behind the messages only: the composer keeps the plain background.
      case messages
    }

    /// The name of the picture kept in the library's folder of images; `nil` without one.
    public var image: String?
    /// Where the user said the picture is, when they gave an address.
    public var imageURL: String?
    /// What the picture shows, when an agent draws it.
    public var imagePrompt: String?
    /// How much of `background` covers the picture, from 0 (the picture as it is) to 1 (hidden).
    public var veil: Double = 0.75
    /// How blurred the picture is, in points.
    public var blur: Double = 0
    public var area: Area = .conversation
    /// Where the picture is on this Mac, found when the theme is read; never written in a file.
    public var localImage: URL?

    public init() {
      // Every value has its default: the built-in themes'.
    }

    /// Whether the theme asks for a picture at all.
    public var wantsImage: Bool { imageURL != nil || imagePrompt != nil || image != nil }

    public static let veilRange: ClosedRange<Double> = 0...1
    public static let blurRange: ClosedRange<Double> = 0...40
  }

  /// How the conversation is laid out, in points, as the Comfortable density draws it: Compact
  /// tightens the spaces.
  public struct Layout: Hashable, Sendable {
    /// Between two messages or tool calls.
    public var blockSpacing: Double = 18
    /// Between two paragraphs of a message.
    public var paragraphSpacing: Double = 10
    /// Above the first message.
    public var topPadding: Double = 28
    /// The height of a line of the messages, as a multiple of the text's size.
    public var lineHeight: Double = 1.25
    /// The widest the column of messages gets.
    public var contentWidth: Double = 820
    /// On each side of the column.
    public var sideMargin: Double = 32
    /// The corners of the user's messages.
    public var bubbleRadius: Double = 16
    /// The corners of the tool calls and of the code blocks.
    public var blockRadius: Double = 10

    public init() {
      // Every value has its default: the built-in themes'.
    }

    /// The corners of what sits inside a block — an output, a table, an image —, a little
    /// tighter than the block's: 8 for the built-in 10.
    public var innerRadius: Double { (blockRadius * 0.8).rounded() }

    public enum Key: String, CaseIterable, Sendable {
      case blockSpacing, paragraphSpacing, topPadding, lineHeight, contentWidth, sideMargin
      case bubbleRadius, blockRadius

      /// What a theme may give it: what still reads, and still lays out.
      public var range: ClosedRange<Double> {
        switch self {
        case .blockSpacing: 4...48
        case .paragraphSpacing: 2...24
        case .topPadding: 0...64
        case .lineHeight: 1...1.8
        case .contentWidth: 560...1200
        case .sideMargin: 8...80
        case .bubbleRadius: 0...24
        case .blockRadius: 0...20
        }
      }
    }

    public subscript(key: Key) -> Double {
      get {
        switch key {
        case .blockSpacing: blockSpacing
        case .paragraphSpacing: paragraphSpacing
        case .topPadding: topPadding
        case .lineHeight: lineHeight
        case .contentWidth: contentWidth
        case .sideMargin: sideMargin
        case .bubbleRadius: bubbleRadius
        case .blockRadius: blockRadius
        }
      }
      set {
        switch key {
        case .blockSpacing: blockSpacing = newValue
        case .paragraphSpacing: paragraphSpacing = newValue
        case .topPadding: topPadding = newValue
        case .lineHeight: lineHeight = newValue
        case .contentWidth: contentWidth = newValue
        case .sideMargin: sideMargin = newValue
        case .bubbleRadius: bubbleRadius = newValue
        case .blockRadius: blockRadius = newValue
        }
      }
    }

    /// The layout at a density: Compact tightens the spaces as it always did — 18 to 10 between
    /// blocks, 10 to 6 between paragraphs, 28 to 14 above the first message.
    public func at(_ density: ConversationAppearance.Density) -> Layout {
      guard density == .compact else { return self }
      var layout = self
      layout.blockSpacing = (blockSpacing * 10 / 18).rounded()
      layout.paragraphSpacing = (paragraphSpacing * 0.6).rounded()
      layout.topPadding = (topPadding * 0.5).rounded()
      return layout
    }
  }

  /// A theme whose every required colour is given; `nil` when one is missing.
  public init?(
    id: String, isDark: Bool, fontStyle: FontStyle, personalName: String? = nil,
    colors: [ColorRole: ThemeColor]
  ) {
    guard ColorRole.allCases.allSatisfy({ $0.isOptional || colors[$0] != nil }) else {
      return nil
    }
    // Every colour is then given its own: those of System Light only fill the memberwise
    // initializer.
    self = Self.systemLight.identified(id, isDark: isDark, fontStyle: fontStyle)
    for role in ColorRole.allCases { self[role] = colors[role] }
    self.personalName = personalName
  }

  private func identified(_ id: String, isDark: Bool, fontStyle: FontStyle) -> ConversationTheme {
    ConversationTheme(
      id: id, isDark: isDark, fontStyle: fontStyle, background: background, surface: surface,
      raised: raised, text: text, secondaryText: secondaryText, border: border, accent: accent,
      onAccent: onAccent, bubble: bubble, bubbleText: bubbleText, bubbleBorder: bubbleBorder,
      codeBackground: codeBackground, codeText: codeText, keyword: keyword, string: string,
      comment: comment, number: number, type: type, function: function,
      addedBackground: addedBackground, addedText: addedText, removedBackground: removedBackground,
      removedText: removedText, success: success, failure: failure, warning: warning,
      warningBackground: warningBackground)
  }

  /// Every colour of the theme, by role; `bubbleBorder` only when it has one.
  public var colors: [ColorRole: ThemeColor] {
    var colors: [ColorRole: ThemeColor] = [:]
    for role in ColorRole.allCases {
      if let color = self[role] { colors[role] = color }
    }
    return colors
  }

  /// A colour by role. Setting `nil` only clears `bubbleBorder`: the others cannot go without.
  public subscript(role: ColorRole) -> ThemeColor? {
    get {
      switch role {
      case .background: background
      case .surface: surface
      case .raised: raised
      case .text: text
      case .secondaryText: secondaryText
      case .border: border
      case .accent: accent
      case .onAccent: onAccent
      case .bubble: bubble
      case .bubbleText: bubbleText
      case .bubbleBorder: bubbleBorder
      case .codeBackground: codeBackground
      case .codeText: codeText
      case .keyword: keyword
      case .string: string
      case .comment: comment
      case .number: number
      case .type: type
      case .function: function
      case .addedBackground: addedBackground
      case .addedText: addedText
      case .removedBackground: removedBackground
      case .removedText: removedText
      case .success: success
      case .failure: failure
      case .warning: warning
      case .warningBackground: warningBackground
      }
    }
    set {
      switch role {
      case .background: if let newValue { background = newValue }
      case .surface: if let newValue { surface = newValue }
      case .raised: if let newValue { raised = newValue }
      case .text: if let newValue { text = newValue }
      case .secondaryText: if let newValue { secondaryText = newValue }
      case .border: if let newValue { border = newValue }
      case .accent: if let newValue { accent = newValue }
      case .onAccent: if let newValue { onAccent = newValue }
      case .bubble: if let newValue { bubble = newValue }
      case .bubbleText: if let newValue { bubbleText = newValue }
      case .bubbleBorder: bubbleBorder = newValue
      case .codeBackground: if let newValue { codeBackground = newValue }
      case .codeText: if let newValue { codeText = newValue }
      case .keyword: if let newValue { keyword = newValue }
      case .string: if let newValue { string = newValue }
      case .comment: if let newValue { comment = newValue }
      case .number: if let newValue { number = newValue }
      case .type: if let newValue { type = newValue }
      case .function: if let newValue { function = newValue }
      case .addedBackground: if let newValue { addedBackground = newValue }
      case .addedText: if let newValue { addedText = newValue }
      case .removedBackground: if let newValue { removedBackground = newValue }
      case .removedText: if let newValue { removedText = newValue }
      case .success: if let newValue { success = newValue }
      case .failure: if let newValue { failure = newValue }
      case .warning: if let newValue { warning = newValue }
      case .warningBackground: if let newValue { warningBackground = newValue }
      }
    }
  }

  /// The pairs a reader must be able to read, with the ratio each needs: text 4.5:1, state
  /// symbols and large text 3:1. Pinned by a test for every built-in theme, and checked for every
  /// theme of the user's before it is shown.
  public static let legibilityRules: [LegibilityRule] = [
    LegibilityRule(name: "text", foreground: .text, background: .background, minimum: 4.5),
    LegibilityRule(
      name: "secondaryText", foreground: .secondaryText, background: .background, minimum: 4.5),
    LegibilityRule(name: "textOnSurface", foreground: .text, background: .surface, minimum: 4.5),
    LegibilityRule(
      name: "secondaryOnSurface", foreground: .secondaryText, background: .surface, minimum: 4.5),
    LegibilityRule(name: "bubbleText", foreground: .bubbleText, background: .bubble, minimum: 4.5),
    LegibilityRule(
      name: "codeText", foreground: .codeText, background: .codeBackground, minimum: 4.5),
    LegibilityRule(
      name: "keyword", foreground: .keyword, background: .codeBackground, minimum: 4.5),
    LegibilityRule(name: "string", foreground: .string, background: .codeBackground, minimum: 4.5),
    LegibilityRule(
      name: "comment", foreground: .comment, background: .codeBackground, minimum: 4.5),
    LegibilityRule(name: "number", foreground: .number, background: .codeBackground, minimum: 4.5),
    LegibilityRule(name: "type", foreground: .type, background: .codeBackground, minimum: 4.5),
    LegibilityRule(
      name: "function", foreground: .function, background: .codeBackground, minimum: 4.5),
    LegibilityRule(
      name: "addedText", foreground: .addedText, background: .addedBackground, minimum: 4.5),
    LegibilityRule(
      name: "removedText", foreground: .removedText, background: .removedBackground, minimum: 4.5
    ),
    LegibilityRule(name: "onAccent", foreground: .onAccent, background: .accent, minimum: 4.5),
    LegibilityRule(name: "success", foreground: .success, background: .surface, minimum: 3),
    LegibilityRule(name: "failure", foreground: .failure, background: .surface, minimum: 3),
    LegibilityRule(name: "warning", foreground: .warning, background: .surface, minimum: 3),
    LegibilityRule(
      name: "warningOnBanner", foreground: .text, background: .warningBackground, minimum: 4.5),
    LegibilityRule(name: "accent", foreground: .accent, background: .background, minimum: 3),
  ]

  /// `legibilityRules`, with this theme's colours.
  public var legibilityPairs:
    [(name: String, foreground: ThemeColor, background: ThemeColor, minimum: Double)]
  {
    Self.legibilityRules.compactMap { rule in
      guard let foreground = self[rule.foreground], let background = self[rule.background] else {
        return nil
      }
      return (rule.name, foreground, background, rule.minimum)
    }
  }

  /// The theme with the user's accent and fonts applied.
  public func applying(_ appearance: ConversationAppearance) -> ConversationTheme {
    var theme = self
    if let accent = Self.accentColors[appearance.accent] {
      theme.accent = isDark ? accent.dark : accent.light
      theme.onAccent = isDark ? "#0B1420" : "#FFFFFF"
    } else if appearance.accent == .custom,
      let custom = appearance.customAccent.flatMap(ThemeColor.init(hex:))
    {
      theme.accent = custom
      // Whichever of black and white reads best on the colour the user chose.
      let white: ThemeColor = "#FFFFFF"
      let black: ThemeColor = "#000000"
      theme.onAccent = custom.contrast(with: white) >= custom.contrast(with: black) ? white : black
    }
    // The user's fonts win over the theme's. The system's own families are reached by their
    // design: SwiftUI does not know them by name.
    switch appearance.messageFont ?? fonts.message {
    case "SF Pro": theme.fontStyle = .system
    case "New York": theme.fontStyle = .serif
    case let family: theme.messageFontFamily = family
    }
    let code = appearance.codeFont ?? fonts.code
    theme.codeFontFamily = code == "SF Mono" ? nil : code
    return theme
  }

  public static let accentColors:
    [ConversationAppearance.Accent: (light: ThemeColor, dark: ThemeColor)] = [
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

  /// A built-in theme, or one of `personal`.
  public static func named(_ identifier: String, personal: [ConversationTheme] = [])
    -> ConversationTheme?
  {
    builtIn.first { $0.id == identifier } ?? personal.first { $0.id == identifier }
  }

  /// The theme in force: the user's choice for the current appearance, Contrast High when macOS
  /// asks for more contrast and the user kept the system's themes. A theme that is no longer
  /// there — a personal one deleted, or whose file can no longer be read — gives the mode's
  /// default one, the setting left as it is.
  public static func resolve(
    _ appearance: ConversationAppearance, isDark: Bool, increasedContrast: Bool,
    personal: [ConversationTheme] = []
  ) -> ConversationTheme {
    let identifier = appearance.themeIdentifier(isDark: isDark)
    let keptSystemThemes =
      identifier == ConversationAppearance.defaultLightTheme
      || identifier == ConversationAppearance.defaultDarkTheme
    let base: ConversationTheme
    if increasedContrast, keptSystemThemes, !isDark {
      base = .highContrast
    } else {
      base = named(identifier, personal: personal) ?? (isDark ? .systemDark : .systemLight)
    }
    return base.applying(appearance)
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
