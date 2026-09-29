import Foundation

/// The JSON schema of a theme's file (#118): what documents the format in the repository
/// (`docs/schemas/conversation-theme-1.schema.json`, held equal to `document` by a test), and what
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
