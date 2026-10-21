import Foundation
import VibeApplication

/// Moves Codex's `/model` panel to a reasoning level, for the session only (#411).
///
/// The panel, as codex-cli 0.162 draws it:
///
///     Select Model and Effort
///     › 1. GPT-6.1-Sol (current)  Latest workhorse model for coding and everyday work.
///       2. GPT-6-Astra            Frontier intelligence for the most demanding work.
///       enter select · esc back
///
///     Select Reasoning Level for GPT-6.1-Sol
///     › 1. Low (default) (current)  Fast responses with lighter reasoning
///       2. Medium                   Balances speed and reasoning depth for everyday tasks
///       …
///       5. More reasoning…          Max and Ultra consume usage limits faster
///       enter default · s session · esc back
///
/// The model in use is kept: its row is chosen again. The level is then chosen with `s`, which
/// applies it to this session; Return would also write it in `config.toml`, for every session, and
/// is never pressed on that panel.
/// Only arrows move the cursor — a digit chooses its row at once, with Return's meaning.
public struct CodexEffortPanel: AgentEffortPanelDriving {
  public let level: String

  public init(level: String) {
    self.level = level
  }

  static let modelTitle = "Select Model and Effort"
  static let levelTitle = "Select Reasoning Level"
  static let moreRow = "More reasoning"
  static let down = "\u{1B}[B"
  static let up = "\u{1B}[A"

  /// The words Codex labels a level with.
  static func label(of level: String) -> String {
    switch level {
    case "xhigh": "Extra high"
    default: level.prefix(1).uppercased() + level.dropFirst()
    }
  }

  public func step(on screen: String) -> AgentEffortPanelStep {
    let lines = screen.components(separatedBy: "\n")
    // The panel drawn last is the one in front: its title is the lowest of the two.
    let modelTitle = lines.lastIndex { $0.contains(Self.modelTitle) }
    let levelTitle = lines.lastIndex { $0.contains(Self.levelTitle) }
    if let levelTitle, levelTitle > (modelTitle ?? -1) {
      return levelStep(Array(lines[levelTitle...]))
    }
    if let modelTitle {
      return modelStep(Array(lines[modelTitle...]))
    }
    return .wait
  }

  /// The model in use, chosen again.
  private func modelStep(_ lines: [String]) -> AgentEffortPanelStep {
    let rows = Self.rows(in: lines)
    guard let target = rows.firstIndex(where: { $0.label.contains("(current)") }) else {
      return .wait
    }
    return move(rows, to: target, then: "\r")
  }

  private func levelStep(_ lines: [String]) -> AgentEffortPanelStep {
    let rows = Self.rows(in: lines)
    let wanted = Self.label(of: level).lowercased()
    if let target = rows.firstIndex(where: { Self.name(of: $0.label).lowercased() == wanted }) {
      // Only `s` applies the level to this session alone. A panel that does not offer it is left
      // as it is — and closed once given up: Return could write it for every session.
      guard lines.contains(where: { $0.contains("s session") }) else { return .wait }
      return move(rows, to: target, then: "s", finishing: true)
    }
    // Max and Ultra are behind a row of their own.
    if let more = rows.firstIndex(where: { $0.label.hasPrefix(Self.moreRow) }) {
      return move(rows, to: more, then: "\r")
    }
    return .wait
  }

  /// The arrows that bring the cursor to a row, or the key pressed once it is there.
  private func move(
    _ rows: [Row], to target: Int, then key: String, finishing: Bool = false
  ) -> AgentEffortPanelStep {
    guard let cursor = rows.firstIndex(where: \.isSelected) else { return .wait }
    if cursor == target { return finishing ? .finish(key) : .press(key) }
    let arrow = target > cursor ? Self.down : Self.up
    return .press(String(repeating: arrow, count: abs(target - cursor)))
  }

  struct Row: Equatable {
    var label: String
    var isSelected: Bool
  }

  /// The numbered rows under a title: `› 2. Medium   Balances…`, the description cut off.
  static func rows(in lines: [String]) -> [Row] {
    var rows: [Row] = []
    for line in lines.dropFirst() {
      var rest = Substring(line.trimmingCharacters(in: .whitespaces))
      let isSelected = rest.hasPrefix("›")
      if isSelected { rest = rest.dropFirst().drop(while: \.isWhitespace) }
      guard let dot = rest.firstIndex(of: "."), !rest[..<dot].isEmpty,
        rest[..<dot].allSatisfy(\.isNumber)
      else {
        if !rows.isEmpty { break }
        continue
      }
      var label = rest[rest.index(after: dot)...].drop(while: \.isWhitespace)
      // Two spaces part the label from its description.
      if let gap = label.range(of: "  ") { label = label[..<gap.lowerBound] }
      rows.append(Row(label: String(label), isSelected: isSelected))
    }
    return rows
  }

  /// A level's row without what Codex adds to it: `Low (default) (current)` is `Low`.
  static func name(of label: String) -> String {
    var name = label
    for mark in ["(current)", "(default)"] {
      name = name.replacingOccurrences(of: mark, with: "")
    }
    return name.trimmingCharacters(in: .whitespaces)
  }
}
