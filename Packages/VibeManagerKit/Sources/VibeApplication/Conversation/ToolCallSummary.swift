import Foundation

/// How a tool call, or a group of them, reads folded: an icon, a title, and a word on how it went.
public struct ToolCallTitle: Hashable, Sendable {
  public let symbolName: String
  public let title: String
  /// Secondary words after the title: the path read, the number of results.
  public let detail: String?
  /// How it ended, when that deserves words — "3 of 42 tests failed", "exit code 2".
  public let outcome: String?

  public init(symbolName: String, title: String, detail: String? = nil, outcome: String? = nil) {
    self.symbolName = symbolName
    self.title = title
    self.detail = detail
    self.outcome = outcome
  }
}

/// Writes the titles of tool calls: "Read Session.swift", "swift test — 42 tests passed".
///
/// Pure: the same call always reads the same way, in the language of the application. A command
/// is shown as the agent wrote it: it is never translated.
public enum ToolCallSummary {
  public static func symbolName(for kind: ToolKind) -> String {
    switch kind {
    case .read: return "doc.text"
    case .edit: return "pencil"
    case .create: return "doc.badge.plus"
    case .shell: return "terminal"
    case .search: return "magnifyingglass"
    case .list: return "list.bullet"
    case .webFetch, .webSearch: return "globe"
    case .mcp: return "puzzlepiece.extension"
    case .subagent: return "person.2"
    case .todo: return "checklist"
    case .plan: return "list.bullet.clipboard"
    case .question: return "questionmark.bubble"
    case .other: return "wrench.and.screwdriver"
    }
  }

  public static func title(for call: ToolCall) -> ToolCallTitle {
    let text = Localizer()
    let symbol = symbolName(for: call.kind)
    let path = call.parameter(.path)
    let file = path.map { ($0 as NSString).lastPathComponent } ?? ""
    switch call.kind {
    case .read:
      let lines = call.parameter(.lines)
      return ToolCallTitle(
        symbolName: symbol, title: text(LocalizedStringResource("Read \(file)", bundle: .module)),
        detail: lines.map { text(LocalizedStringResource("lines \($0)", bundle: .module)) }
          ?? directory(of: path))
    case .edit:
      return ToolCallTitle(
        symbolName: symbol,
        title: call.changes.count > 1
          ? text(LocalizedStringResource("Edited \(call.changes.count) files", bundle: .module))
          : text(LocalizedStringResource("Edited \(editedName(call, file))", bundle: .module)),
        detail: directory(of: path ?? call.changes.first?.path))
    case .create:
      return ToolCallTitle(
        symbolName: symbol,
        title: text(LocalizedStringResource("Created \(editedName(call, file))", bundle: .module)),
        detail: directory(of: path ?? call.changes.first?.path))
    case .shell:
      let command = firstLine(of: call.parameter(.command) ?? "")
      let title = call.summary.map(firstLine) ?? command
      return ToolCallTitle(
        symbolName: symbol, title: title,
        detail: call.summary == nil ? nil : command,
        outcome: shellOutcome(call, text))
    case .search:
      let pattern = call.parameter(.pattern) ?? call.parameter(.query) ?? ""
      return ToolCallTitle(
        symbolName: symbol,
        title: text(LocalizedStringResource("Searched for \(pattern)", bundle: .module)),
        detail: call.facts.resultCount.map {
          text(LocalizedStringResource("\($0) results", bundle: .module))
        } ?? call.parameter(.path))
    case .list:
      return ToolCallTitle(
        symbolName: symbol,
        title: path.map { text(LocalizedStringResource("Listed \($0)", bundle: .module)) }
          ?? text(LocalizedStringResource("Listed files", bundle: .module)),
        detail: call.facts.resultCount.map {
          text(LocalizedStringResource("\($0) results", bundle: .module))
        })
    case .webFetch:
      let url = call.parameter(.url) ?? ""
      let host = URL(string: url)?.host() ?? url
      return ToolCallTitle(
        symbolName: symbol, title: text(LocalizedStringResource("Read \(host)", bundle: .module)),
        detail: url)
    case .webSearch:
      let query = call.parameter(.query) ?? ""
      return ToolCallTitle(
        symbolName: symbol,
        title: text(LocalizedStringResource("Searched the web for \(query)", bundle: .module)))
    case .mcp(let server, let tool):
      return ToolCallTitle(symbolName: symbol, title: "\(server) · \(tool)")
    case .subagent:
      let description = call.parameter(.description) ?? call.summary ?? ""
      return ToolCallTitle(
        symbolName: symbol,
        title: text(LocalizedStringResource("Sub-agent: \(description)", bundle: .module)))
    case .todo:
      return ToolCallTitle(
        symbolName: symbol, title: text(LocalizedStringResource("To-do list", bundle: .module)),
        detail: call.facts.resultCount.map { done in
          text(
            LocalizedStringResource(
              "\(done) of \(call.facts.lineCount ?? done) done", bundle: .module))
        })
    case .plan:
      return ToolCallTitle(
        symbolName: symbol, title: text(LocalizedStringResource("Plan", bundle: .module)))
    case .question:
      return ToolCallTitle(
        symbolName: symbol,
        title: call.parameter(.question).map(firstLine)
          ?? text(LocalizedStringResource("Question", bundle: .module)))
    case .other(let name):
      return ToolCallTitle(symbolName: symbol, title: name)
    }
  }

  /// A group reads as what its calls did together: "5 files read", "3 searches".
  public static func title(forGroup calls: [ToolCall]) -> ToolCallTitle {
    let text = Localizer()
    guard let first = calls.first else {
      return ToolCallTitle(symbolName: "wrench.and.screwdriver", title: "")
    }
    let count = calls.count
    let symbol = symbolName(for: first.kind)
    let names = calls.compactMap { call in
      (call.parameter(.path) ?? call.changes.first?.path).map { ($0 as NSString).lastPathComponent }
    }
    let failures = calls.filter {
      if case .failed = $0.state { return true }
      return false
    }.count
    let outcome =
      failures > 0 ? text(LocalizedStringResource("\(failures) failed", bundle: .module)) : nil
    let listed = names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
    let title: String
    switch first.kind {
    case .read: title = text(LocalizedStringResource("\(count) files read", bundle: .module))
    case .edit, .create:
      title = text(LocalizedStringResource("\(count) files edited", bundle: .module))
    case .shell: title = text(LocalizedStringResource("\(count) commands", bundle: .module))
    case .search, .list: title = text(LocalizedStringResource("\(count) searches", bundle: .module))
    case .webFetch, .webSearch:
      title = text(LocalizedStringResource("\(count) web lookups", bundle: .module))
    case .mcp(let server, _):
      title = text(LocalizedStringResource("\(count) calls to \(server)", bundle: .module))
    case .other(let name):
      title = text(LocalizedStringResource("\(count) calls to \(name)", bundle: .module))
    case .subagent, .todo, .plan, .question:
      title = text(LocalizedStringResource("\(count) calls", bundle: .module))
    }
    let detail: String?
    switch first.kind {
    case .shell:
      detail = calls.map { firstLine(of: $0.parameter(.command) ?? "") }.joined(separator: " · ")
    case .search, .list:
      detail = calls.compactMap { $0.parameter(.pattern) ?? $0.parameter(.query) }
        .joined(separator: " · ")
    default:
      detail = listed
    }
    return ToolCallTitle(symbolName: symbol, title: title, detail: detail, outcome: outcome)
  }

  private static func shellOutcome(_ call: ToolCall, _ text: Localizer) -> String? {
    if let tests = call.facts.tests {
      return tests.failed == 0
        ? text(LocalizedStringResource("\(tests.total) tests passed", bundle: .module))
        : text(
          LocalizedStringResource("\(tests.failed) of \(tests.total) tests failed", bundle: .module)
        )
    }
    switch call.state {
    case .failed(let code):
      return code.map { text(LocalizedStringResource("exit code \(String($0))", bundle: .module)) }
        ?? text(LocalizedStringResource("failed", bundle: .module))
    case .refused: return text(LocalizedStringResource("not allowed", bundle: .module))
    case .interrupted: return text(LocalizedStringResource("interrupted", bundle: .module))
    default: return nil
    }
  }

  private static func editedName(_ call: ToolCall, _ file: String) -> String {
    file.isEmpty ? (call.changes.first?.fileName ?? "") : file
  }

  private static func directory(of path: String?) -> String? {
    guard let path, path.contains("/") else { return nil }
    let directory = (path as NSString).deletingLastPathComponent
    return directory.isEmpty ? nil : (directory as NSString).abbreviatingWithTildeInPath
  }

  static func firstLine(of text: String) -> String {
    let line =
      text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
  }
}

/// Resolves this module's strings in the language of the application.
struct Localizer {
  func callAsFunction(_ resource: LocalizedStringResource) -> String {
    String(localized: resource)
  }
}
