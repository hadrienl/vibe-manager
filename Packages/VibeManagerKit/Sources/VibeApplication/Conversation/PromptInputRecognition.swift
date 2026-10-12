import Foundation

/// What an agent's prompt holds, read from its screen (#370): whether the text typed into it has
/// arrived, and, once Return is written, whether it was sent.
///
/// Claude Code 2.1.296 draws its prompt between two rules, the first line opening on `❯`, the next
/// ones indented by two columns. The prompt sent leaves it empty, or showing a hint; one not sent
/// keeps the text — followed by an empty line when Return was taken for a line break. A screen
/// without such a prompt — a panel, a terminal too short — tells nothing.
public enum PromptInputRecognition {
  /// The lines of the prompt, its pointer and indent removed; nil when the screen shows none.
  public static func input(screen: String) -> [String]? {
    let lines = screen.components(separatedBy: "\n")
    guard
      let start = lines.indices.last(where: { index in
        index > 0 && lines[index].hasPrefix("❯") && isRule(lines[index - 1])
      }),
      let end = lines[(start + 1)...].firstIndex(where: isRule)
    else { return nil }
    var input = [String(lines[start].dropFirst().drop(while: isBlank))]
    for line in lines[(start + 1)..<end] {
      input.append(String(line.dropFirst(min(2, line.prefix(while: isBlank).count))))
    }
    return input
  }

  /// Whether the prompt ends on `text`, the images joined after it aside. Lines are wrapped where
  /// the prompt is narrow, blanks may fall at a wrap, and an emoji may be drawn otherwise: only
  /// letters, digits and punctuation are compared. A text shorter than `tailLength` is the whole
  /// prompt, never a word of a hint — `Try "fix lint errors"` holds no "fix".
  public static func holds(_ text: String, in input: [String]) -> Bool {
    let expected = comparable(text)
    guard !expected.isEmpty else { return false }
    // Claude Code shows `[Image #1]` in place of an image whose path was typed after the text.
    let shown = comparable(input.joined(separator: " ").replacing(/\[Image #\d+\]/, with: ""))
    guard expected.count > tailLength else { return shown == expected }
    return shown.hasSuffix(expected.suffix(tailLength))
  }

  /// Claude Code shows a long text arriving at once as a placeholder rather than the text.
  public static func showsPastedText(_ input: [String]) -> Bool {
    input.contains { $0.contains("[Pasted text") }
  }

  /// Whether the prompt ends on an empty line: a text sent is trimmed, so such a line is a Return
  /// taken for a line break.
  public static func endsOnLineBreak(_ input: [String]) -> Bool {
    input.count > 1 && input.last?.allSatisfy(\.isWhitespace) == true
  }

  /// A rule of Claude Code's screen, across a prompt or between a question's options.
  static func isRule(_ line: String) -> Bool {
    let rest = line.trimmingCharacters(in: .whitespaces)
    return !rest.isEmpty && rest.allSatisfy { "─━".contains($0) }
  }

  /// How much of the end of a long text is looked for: enough to tell it from a hint.
  static let tailLength = 32

  private static func comparable(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.filter { scalar in
          scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            || (scalar.isASCII && scalar.properties.generalCategory.isPunctuation)
        }))
  }

  private static func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\u{A0}"
  }
}

extension Unicode.GeneralCategory {
  fileprivate var isPunctuation: Bool {
    switch self {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol:
      true
    default: false
    }
  }
}
