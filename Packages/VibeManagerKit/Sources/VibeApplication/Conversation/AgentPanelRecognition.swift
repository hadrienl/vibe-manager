import Foundation

/// Whether an agent's terminal shows one of its panels — `/mcp`, `/model` — read from the last
/// lines of its screen (#219).
///
/// The CLIs write nothing of a panel closed with Escape: only the screen says it is gone. Every
/// panel of both ends on a hint of the keys that close it — Claude Code 2.1.285 "Enter to confirm ·
/// Esc to cancel", Codex 0.159.2 "enter select · esc back" — which neither prompt shows at rest,
/// and which a turn under way words as "esc to interrupt". The panel takes the prompt's place: no
/// prompt is drawn under its hint.
public enum AgentPanelRecognition {
  /// How many of the last lines with text are read: a panel's hint is its last line or so.
  static let lineCount = 6

  private static let hint = try? NSRegularExpression(
    pattern: #"\besc(ape)?\s+(to\s+)?(cancel|go back|back|exit|close|dismiss|quit)\b"#,
    options: [.caseInsensitive])

  public static func showsPanel(screen: String) -> Bool {
    guard let hint else { return false }
    let lines = screen.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let read = Array(lines.suffix(lineCount))
    guard
      let last = read.lastIndex(where: { line in
        hint.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
      })
    else { return false }
    // The prompt drawn under the hint: it is the agent's own words, written above the prompt at
    // rest — "press Esc to exit the editor" — not a panel, which takes the prompt's place (#319).
    return !read[(last + 1)...].contains(where: isPrompt)
  }

  /// The line the prompt is typed on: `❯` for Claude Code, `›` for Codex. A panel's options start
  /// with the same pointer, but above its hint.
  private static func isPrompt(_ line: String) -> Bool {
    line.hasPrefix("❯") || line.hasPrefix("›")
  }
}
