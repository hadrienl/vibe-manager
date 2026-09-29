import Foundation

/// The JSON schema of a theme's file (#118): what documents the format in the repository
/// (`docs/schemas/conversation-theme-3.schema.json`, held equal to `document` by a test), and what
/// an agent's answer is held to.
public enum ConversationThemeSchema {
  /// What each colour is for, as the agent is told.
  public static func purpose(of role: ConversationTheme.ColorRole) -> String {
    switch role {
    case .background: "Background of the whole conversation."
    case .surface: "Background of the rows of tool calls and of the cards drawn on the background."
    case .raised: "Background of what is raised above the surface: menus, popovers."
    case .text: "Main text, on the background and on the surface."
    case .secondaryText: "Secondary text — captions, times, hints — on the background and surface."
    case .border: "Borders and separators."
    case .accent: "Accent: links, the active state, the send button, the agent's activity dot."
    case .onAccent: "Text and symbols drawn on the accent."
    case .bubble: "Background of the user's messages."
    case .bubbleText: "Text of the user's messages."
    case .bubbleBorder:
      "Border around the user's messages, only when the bubble is too close to the background to "
        + "be told apart from it; null otherwise."
    case .codeBackground: "Background of code blocks and inline code."
    case .codeText: "Plain text of code."
    case .keyword: "Syntax highlighting: keywords."
    case .string: "Syntax highlighting: string literals."
    case .comment: "Syntax highlighting: comments."
    case .number: "Syntax highlighting: number literals."
    case .type: "Syntax highlighting: type names."
    case .function: "Syntax highlighting: function names."
    case .addedBackground: "Background of a line added in a diff."
    case .addedText: "Text of a line added in a diff."
    case .removedBackground: "Background of a line removed in a diff."
    case .removedText: "Text of a line removed in a diff."
    case .success: "Symbol of a tool call that succeeded, on the surface."
    case .failure: "Symbol of a tool call that failed, on the surface."
    case .warning: "Symbol of a warning, on the surface."
    case .warningBackground: "Background of a warning banner; its text is the main text colour."
    }
  }

  /// What each number of the layout is, as the agent is told.
  public static func purpose(of key: ConversationTheme.Layout.Key) -> String {
    let base = ConversationTheme.Layout()[key]
    let range = key.range
    let what: String =
      switch key {
      case .blockSpacing: "Points between two messages or tool calls."
      case .paragraphSpacing: "Points between two paragraphs of a message."
      case .topPadding: "Points above the first message."
      case .lineHeight: "Height of a line of the messages, as a multiple of the text size."
      case .contentWidth: "Widest the column of messages gets, in points."
      case .sideMargin: "Points on each side of the column of messages."
      case .bubbleRadius: "Corner radius of the user's messages, in points."
      case .blockRadius: "Corner radius of the tool calls and code blocks, in points."
      }
    return
      "\(what) From \(ConversationThemeFile.number(range.lowerBound)) to "
      + "\(ConversationThemeFile.number(range.upperBound)); the built-in themes use "
      + "\(ConversationThemeFile.number(base))."
  }

  /// What each font is, as the agent is told.
  static func purpose(of key: ConversationThemeFile.FontKey) -> String {
    switch key {
    case .message:
      "The family of the messages: a font every Mac has (SF Pro, New York, Avenir Next, Charter, "
        + "Iowan Old Style, Helvetica Neue, Georgia…) or the exact name of any Google Fonts family, "
        + "which the application downloads. null keeps the system family of fontStyle."
    case .code:
      "The monospaced family of the code: SF Mono, Menlo, Monaco, or the exact name of a "
        + "monospaced Google Fonts family (JetBrains Mono, Fira Code, IBM Plex Mono…). null keeps "
        + "SF Mono."
    }
  }

  /// What each key of the backdrop is, as the agent is told.
  static func purpose(of key: ConversationThemeFile.BackdropKey) -> String {
    switch key {
    case .image:
      "Set by the application: the name of the picture it kept. Never given by an agent."
    case .imageURL:
      "An https address of a picture that the user wrote in their description, copied exactly; "
        + "the application downloads it. null otherwise: never make an address up."
    case .imagePrompt:
      "When the user wants a picture behind the conversation and gave no address: what it shows, "
        + "in English, for an image generation model — subject, mood, colours, blur, landscape "
        + "16:10, no text. null for no picture, or when imageURL is given."
    case .veil:
      "How much of colors.background covers the picture, from 0 (the picture as it is) to 1 "
        + "(hidden). The text is read on colors.background: 0.6 to 0.9 keeps it readable."
    case .blur:
      "How blurred the picture is, in points, from 0 to 40."
    case .area:
      "\"conversation\": behind the messages and the composer; \"messages\": behind the "
        + "messages only."
    }
  }

  /// The schema of the file, as the repository documents it.
  public static var document: String {
    render(
      schema(forAgent: false, isDark: nil).merging(
        [
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Vibe Manager conversation theme, format \(ConversationThemeFile.format)",
          "description":
            "A personal theme of the conversation view. Its file name is its identifier; "
            + "every pair of colours a reader must read is also held to WCAG contrasts, which a "
            + "schema cannot say.",
        ], uniquingKeysWith: { current, _ in current }))
  }

  /// The schema an agent's answer is held to: what `--json-schema` of Claude Code and
  /// `--output-schema` of Codex accept — every property required, no other allowed, and none of
  /// the keywords the strict mode of the latter refuses.
  public static func forAgent(isDark: Bool) -> String {
    render(schema(forAgent: true, isDark: isDark))
  }

  private static func schema(forAgent: Bool, isDark: Bool?) -> [String: Any] {
    var colors: [String: Any] = [:]
    for role in ConversationTheme.ColorRole.allCases {
      var property: [String: Any] = [
        "type": role.isOptional ? ["string", "null"] as [Any] : "string",
        "pattern": "^#[0-9A-Fa-f]{6}$",
        "description": purpose(of: role),
      ]
      if role.isOptional, !forAgent { property["default"] = NSNull() }
      colors[role.rawValue] = property
    }
    var name: [String: Any] = [
      "type": "string",
      "description":
        "The theme's name, in the user's language: a few evocative words, "
        + "\(ConversationThemeFile.maximumNameLength) characters at most.",
    ]
    if !forAgent {
      name["minLength"] = 1
      name["maxLength"] = ConversationThemeFile.maximumNameLength
    }
    var fonts: [String: Any] = [:]
    for key in ConversationThemeFile.FontKey.allCases {
      var property: [String: Any] = [
        "type": ["string", "null"] as [Any], "description": purpose(of: key),
      ]
      if !forAgent {
        property["pattern"] = "^[A-Za-z0-9-]([A-Za-z0-9 -]*[A-Za-z0-9-])?$"
        property["maxLength"] = ConversationThemeFile.maximumFontNameLength
      }
      fonts[key.rawValue] = property
    }
    var layout: [String: Any] = [:]
    for key in ConversationTheme.Layout.Key.allCases {
      var property: [String: Any] = ["type": "number", "description": purpose(of: key)]
      if !forAgent {
        property["minimum"] = key.range.lowerBound
        property["maximum"] = key.range.upperBound
      }
      layout[key.rawValue] = property
    }
    var backdrop: [String: Any] = [:]
    for key in ConversationThemeFile.BackdropKey.allCases where !(forAgent && key == .image) {
      var property: [String: Any] = ["description": purpose(of: key)]
      switch key {
      case .image, .imageURL, .imagePrompt:
        property["type"] = ["string", "null"] as [Any]
      case .veil, .blur:
        property["type"] = "number"
        if !forAgent {
          let range =
            key == .veil
            ? ConversationTheme.Backdrop.veilRange : ConversationTheme.Backdrop.blurRange
          property["minimum"] = range.lowerBound
          property["maximum"] = range.upperBound
        }
      case .area:
        property["type"] = "string"
        property["enum"] = ConversationTheme.Backdrop.Area.allCases.map(\.rawValue)
      }
      backdrop[key.rawValue] = property
    }
    // `image` is the application's, and only there when a picture was kept: never required.
    let backdropKeys = ConversationThemeFile.BackdropKey.allCases.filter { $0 != .image }
      .map(\.rawValue)
    var dark: [String: Any] = ["type": "boolean", "description": "Whether the theme is dark."]
    // Said rather than pinned with `enum`, which not every strict mode takes on a boolean: the
    // answer is checked against the mode asked for anyway.
    if let isDark {
      dark["description"] =
        isDark
        ? "Must be true: a dark theme is asked for." : "Must be false: a light theme is asked for."
    }
    return [
      "type": "object",
      "additionalProperties": false,
      "required": ConversationThemeFile.Key.allCases.map(\.rawValue),
      "properties": [
        "format": [
          "type": "integer", "enum": [ConversationThemeFile.format],
          "description": "The version of the format.",
        ] as [String: Any],
        "name": name,
        "isDark": dark,
        "fontStyle": [
          "type": "string",
          "enum": ConversationTheme.FontStyle.allCases.map(\.rawValue),
          "description":
            "The family of the messages' font: the system's sans serif, a serif, or monospaced.",
        ] as [String: Any],
        "colors": [
          "type": "object",
          "additionalProperties": false,
          "required": ConversationTheme.ColorRole.allCases.map(\.rawValue),
          "properties": colors,
        ] as [String: Any],
        "fonts": [
          "type": "object",
          "additionalProperties": false,
          "required": ConversationThemeFile.FontKey.allCases.map(\.rawValue),
          "properties": fonts,
        ] as [String: Any],
        "layout": [
          "type": "object",
          "additionalProperties": false,
          "required": ConversationTheme.Layout.Key.allCases.map(\.rawValue),
          "properties": layout,
        ] as [String: Any],
        "backdrop": [
          "type": "object",
          "additionalProperties": false,
          "required": backdropKeys,
          "properties": backdrop,
        ] as [String: Any],
      ] as [String: Any],
    ]
  }

  private static func render(_ object: [String: Any]) -> String {
    let data =
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
  }
}
