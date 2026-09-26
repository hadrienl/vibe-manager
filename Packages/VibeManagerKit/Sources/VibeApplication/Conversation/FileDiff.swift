import Foundation

/// What a call did to one file, as a unified diff cut in hunks.
public struct FileDiff: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case added, modified, deleted
  }

  public let path: String
  public let kind: Kind
  public var hunks: [DiffHunk]
  /// Lines left out past `DiffHunk.lineLimit`: the header still says how big the change was.
  public var omittedLineCount: Int

  public init(path: String, kind: Kind, hunks: [DiffHunk], omittedLineCount: Int = 0) {
    self.path = path
    self.kind = kind
    self.hunks = hunks
    self.omittedLineCount = omittedLineCount
  }

  public var addedLineCount: Int {
    hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
  }

  public var removedLineCount: Int {
    hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
  }

  public var fileName: String {
    (path as NSString).lastPathComponent
  }
}

public struct DiffHunk: Hashable, Sendable {
  /// More than this, per file, and the rest is counted rather than kept.
  public static let lineLimit = 2_000

  public let oldStart: Int
  public let newStart: Int
  public var lines: [DiffLine]

  public init(oldStart: Int, newStart: Int, lines: [DiffLine]) {
    self.oldStart = oldStart
    self.newStart = newStart
    self.lines = lines
  }
}

public struct DiffLine: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case context, added, removed
  }

  public let kind: Kind
  public let text: String
  public let oldNumber: Int?
  public let newNumber: Int?

  public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
    self.kind = kind
    self.text = text
    self.oldNumber = oldNumber
    self.newNumber = newNumber
  }
}

/// Reads the hunks of a unified diff: `@@ -a,b +c,d @@` headers, then lines that start with a
/// space, `+` or `-`. File headers and `\ No newline at end of file` are skipped. When a header
/// gives line counts, every line they cover is content, even one that reads `--- ` or `+++ `.
public enum UnifiedDiffParser {
  public static func hunks(in text: String, limit: Int = DiffHunk.lineLimit) -> (
    hunks: [DiffHunk], omitted: Int
  ) {
    var hunks: [DiffHunk] = []
    var current: DiffHunk?
    var oldLine = 0
    var newLine = 0
    // Lines the hunk header announces and that are still to come; nil when it gives no counts.
    var remaining: (old: Int, new: Int)?
    var kept = 0
    var omitted = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
      if line.hasPrefix("@@") {
        if let current { hunks.append(current) }
        let range = header(String(line))
        oldLine = range.oldStart
        newLine = range.newStart
        remaining = range.counts
        current = DiffHunk(oldStart: range.oldStart, newStart: range.newStart, lines: [])
        continue
      }
      guard current != nil, let first = line.first else { continue }
      // Past the announced lines, whatever comes before the next `@@` is a file header.
      if let left = remaining, left.old <= 0, left.new <= 0 { continue }
      let isFileHeader = remaining == nil && (line.hasPrefix("+++ ") || line.hasPrefix("--- "))
      let body = String(line.dropFirst())
      let parsed: DiffLine
      switch first {
      case "+":
        guard !isFileHeader else { continue }
        parsed = DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newLine)
        newLine += 1
        remaining?.new -= 1
      case "-":
        guard !isFileHeader else { continue }
        parsed = DiffLine(kind: .removed, text: body, oldNumber: oldLine, newNumber: nil)
        oldLine += 1
        remaining?.old -= 1
      case " ":
        parsed = DiffLine(kind: .context, text: body, oldNumber: oldLine, newNumber: newLine)
        oldLine += 1
        newLine += 1
        remaining?.old -= 1
        remaining?.new -= 1
      default:
        continue
      }
      if kept < limit {
        current?.lines.append(parsed)
        kept += 1
      } else {
        omitted += 1
      }
    }
    if let current { hunks.append(current) }
    return (hunks, omitted)
  }

  /// A whole new file, shown as one hunk of added lines.
  public static func addition(of content: String, limit: Int = DiffHunk.lineLimit) -> (
    hunks: [DiffHunk], omitted: Int
  ) {
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    let kept = lines.prefix(limit).enumerated().map { index, text in
      DiffLine(kind: .added, text: String(text), oldNumber: nil, newNumber: index + 1)
    }
    return ([DiffHunk(oldStart: 0, newStart: 1, lines: kept)], max(0, lines.count - limit))
  }

  private static func header(_ line: String) -> (
    oldStart: Int, newStart: Int, counts: (old: Int, new: Int)?
  ) {
    // @@ -12,7 +12,9 @@ optional section name — a missing count means one line.
    // Codex's patches write a bare `@@`, with neither starts nor counts.
    let parts = line.split(separator: " ")
    func range(_ prefix: Character) -> (start: Int, count: Int)? {
      guard let part = parts.first(where: { $0.first == prefix }) else { return nil }
      let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
      guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
      return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
    }
    guard let old = range("-"), let new = range("+") else {
      return (range("-")?.start ?? 1, range("+")?.start ?? 1, nil)
    }
    return (old.start, new.start, (old.count, new.count))
  }
}
