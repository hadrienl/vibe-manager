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

  /// Whether the prompt shows the end of `text`. Lines are wrapped where the prompt is narrow, and
  /// spaces may fall at a wrap: both are compared without their blanks.
  public static func holds(_ text: String, in input: [String]) -> Bool {
    let expected = String(text.filter { !$0.isWhitespace }.suffix(tailLength))
    guard !expected.isEmpty else { return false }
    return input.joined().filter { !$0.isWhitespace }.contains(expected)
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

  /// How much of the end of a text is looked for: enough to tell it from a hint.
  static let tailLength = 32

  private static func isRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 4 && trimmed.allSatisfy { $0 == "─" }
  }

  private static func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\u{A0}"
  }
}
