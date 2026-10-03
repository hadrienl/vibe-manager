import Foundation
import VibeApplication

/// Which request the approval dialog Codex draws last is, read off the screen (#283).
///
/// Codex's notification quotes a command cut short, a file's name, a server's: two requests can
/// fit it. The dialog itself shows all of it — the command whole, every file's path, the host —
/// as `tui/src/bottom_pane/approval_overlay.rs` draws it in 0.159, wrapped to the terminal's width.
/// When the terminal is too short for it, Codex leaves out the top of what it asks and says how
/// many lines it left out: then nothing is read.
///
/// Not an MCP tool's form: it names the tool, but shows its arguments shortened, cut, and not all
/// of them (`mcp_server_elicitation.rs`). Two calls of the same tool look the same there; they are
/// answered in the session.
enum CodexDrawnDialogReading {
  static let commandTitle = "Would you like to run the following command?"
  static let editsTitle = "Would you like to make the following edits?"
  static let destination = "Destination:"

  /// The dialog the screen ends on, or `nil` when it does not end on one of Codex's approvals, or
  /// shows only part of what it asks.
  static func dialog(onScreen text: String) -> AgentDrawnDialog? {
    guard AgentDialogScreen(screen: text) != nil else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let options = lines.lastIndex(where: isFirstOption),
      let start = lines[..<options].lastIndex(where: isTitle)
    else { return nil }
    // A command's or a patch's title fits a line; a host's runs on until a blank one.
    let titleEnd =
      [commandTitle, editsTitle].contains(lines[start])
      ? start + 1 : lines[start..<options].firstIndex(where: \.isEmpty) ?? options
    let title = lines[start..<titleEnd].joined(separator: " ")
    let header = Array(lines[titleEnd..<options])
    guard !header.contains(where: isLeftOut) else { return nil }
    switch title {
    case commandTitle:
      guard let dollar = header.firstIndex(where: { $0.hasPrefix("$ ") }) else { return nil }
      let command = ([String(header[dollar].dropFirst(2))] + header[(dollar + 1)...])
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      return command.isEmpty ? nil : AgentDrawnDialog(.shownCommand(command))
    case editsTitle:
      let paths = destinations(in: header)
      return paths.isEmpty ? nil : AgentDrawnDialog(.patch(paths))
    default:
      return quoted(in: title, after: "network access to ").map { AgentDrawnDialog(.host($0)) }
    }
  }

  /// `› 1. Yes, proceed (y)`, `1. Allow`: where the options start.
  static func isFirstOption(_ line: String) -> Bool {
    line.hasPrefix("› 1. ") || line.hasPrefix("1. ")
  }

  static func isTitle(_ line: String) -> Bool {
    line == commandTitle || line == editsTitle
      || line.hasPrefix("Do you want to approve network access to ")
      || line.hasPrefix("Do you want to allow network access to ")
  }

  /// `[… 9 lines] ctrl+a view all`: the top of what the dialog asks is not drawn.
  static func isLeftOut(_ line: String) -> Bool {
    line.hasPrefix("[…") || line.hasPrefix("[...")
  }

  /// Every path after a `Destination:`, its wrapped lines joined, up to a blank line or the next.
  static func destinations(in header: [String]) -> Set<String> {
    var paths: Set<String> = []
    var current: String?
    for line in header {
      if line.hasPrefix(destination) {
        if let current, !current.isEmpty { paths.insert(current) }
        current = String(line.dropFirst(destination.count))
      } else if line.isEmpty {
        if let current, !current.isEmpty { paths.insert(current) }
        current = nil
      } else if let path = current {
        current = path + line
      }
    }
    if let current, !current.isEmpty { paths.insert(current) }
    return Set(paths.map { $0.trimmingCharacters(in: .whitespaces) })
  }

  /// `Do you want to approve network access to "example.org"?` gives `example.org`.
  static func quoted(in title: String, after words: String) -> String? {
    guard let range = title.range(of: words) else { return nil }
    var rest = title[range.upperBound...]
    if rest.hasSuffix("?") { rest = rest.dropLast() }
    if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
      rest = rest.dropFirst().dropLast()
    }
    let host = rest.trimmingCharacters(in: .whitespaces)
    return host.isEmpty ? nil : host
  }
}
