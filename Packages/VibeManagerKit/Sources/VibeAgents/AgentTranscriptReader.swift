import Foundation
import VibeApplication
import VibeDomain

/// Reads what a session's agent did from the transcripts its CLI writes: the files it edited and
/// the folders its commands ran from.
///
/// Claude Code writes `projects/<folder>/<session id>.jsonl`, and one file per sub-agent under
/// `<session id>/subagents/`; every line carries the `cwd` of the moment, and the editing tools
/// carry the `file_path` they wrote. Codex writes `sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`, whose
/// lines carry a `cwd`, the `workdir` of its commands, and patches naming the files they touch.
///
/// Only read, never written, and read incrementally: a transcript grows to megabytes and the
/// report is asked for every thirty seconds, so each file is resumed where the last reading
/// stopped.
public actor AgentTranscriptReader: SessionTranscriptReading {
  private let claudeProjects: URL
  private let codexSessions: URL
  private var progress: [String: FileProgress] = [:]

  struct FileProgress {
    var offset: UInt64 = 0
    var activity = TranscriptActivity()
    /// Codex names patched files relative to where the command ran.
    var lastDirectory: String?
  }

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory()
  ) {
    self.claudeProjects = claudeProjects
    self.codexSessions = codexSessions
  }

  public func activity(for session: WorkSession) async -> TranscriptActivity? {
    guard let agent = session.agent,
      let identifier = agent.resumeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }

    let files: [URL]
    let isCodex: Bool
    switch agent.providerID {
    case ClaudeCodeAgentProvider.id.rawValue:
      files = claudeTranscripts(for: identifier)
      isCodex = false
    case CodexAgentProvider.id.rawValue:
      files = codexRollouts(for: identifier, since: session.createdAt)
      isCodex = true
    default:
      return nil
    }
    guard !files.isEmpty else { return nil }

    var activity = TranscriptActivity()
    for file in files {
      let read = advance(file, isCodex: isCodex)
      activity.editedPaths.formUnion(read.editedPaths)
      activity.workingDirectories.formUnion(read.workingDirectories)
    }
    return activity
  }

  // MARK: - Finding the files

  private func claudeTranscripts(for identifier: String) -> [URL] {
    let manager = FileManager.default
    guard
      let folders = try? manager.contentsOfDirectory(
        at: claudeProjects, includingPropertiesForKeys: nil)
    else { return [] }
    var found: [URL] = []
    for folder in folders {
      let main = folder.appendingPathComponent("\(identifier).jsonl")
      guard manager.fileExists(atPath: main.path) else { continue }
      found.append(main)
      let subagents = folder.appendingPathComponent(identifier).appendingPathComponent(
        "subagents")
      if let files = try? manager.contentsOfDirectory(
        at: subagents, includingPropertiesForKeys: nil)
      {
        found.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
      }
    }
    return found
  }

  /// Only the days the session can have written in are listed, from the day before it was
  /// created: a Codex home holds months of rollouts.
  private func codexRollouts(for identifier: String, since created: Date) -> [URL] {
    let manager = FileManager.default
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var day = calendar.startOfDay(for: created.addingTimeInterval(-86_400))
    let today = calendar.startOfDay(for: Date())
    var found: [URL] = []
    while day <= today {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let folder =
        codexSessions
        .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
      if let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
        found.append(
          contentsOf: files.filter {
            $0.lastPathComponent.contains(identifier) && $0.pathExtension == "jsonl"
          })
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return found
  }

  // MARK: - Reading them

  private func advance(_ file: URL, isCodex: Bool) -> TranscriptActivity {
    var state = progress[file.path] ?? FileProgress()
    guard let handle = try? FileHandle(forReadingFrom: file) else { return state.activity }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    // A file that shrank was replaced: it is read again from the start.
    if size < state.offset { state = FileProgress() }
    try? handle.seek(toOffset: state.offset)
    let data = (try? handle.readToEnd()) ?? Data()
    // Only whole lines: the CLI may be in the middle of writing the last one.
    guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
      progress[file.path] = state
      return state.activity
    }
    let complete = data[data.startIndex...lastNewline]
    state.offset += UInt64(complete.count)
    for line in complete.split(separator: UInt8(ascii: "\n")) {
      if isCodex {
        Self.readCodex(line: Data(line), into: &state)
      } else {
        Self.readClaude(line: Data(line), into: &state.activity)
      }
    }
    progress[file.path] = state
    return state.activity
  }

  static let claudeEditingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  static func readClaude(line: Data, into activity: inout TranscriptActivity) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }
    if let cwd = object["cwd"] as? String, cwd.hasPrefix("/") {
      activity.workingDirectories.insert(cwd)
    }
    guard let message = object["message"] as? [String: Any],
      let content = message["content"] as? [[String: Any]]
    else { return }
    for item in content where item["type"] as? String == "tool_use" {
      guard let name = item["name"] as? String, claudeEditingTools.contains(name),
        let input = item["input"] as? [String: Any]
      else { continue }
      for key in ["file_path", "notebook_path"] {
        if let path = input[key] as? String, path.hasPrefix("/") {
          activity.editedPaths.insert(path)
        }
      }
    }
  }

  /// Codex has changed the shape of its tool calls more than once, and a command's arguments are
  /// often JSON inside a string. The line is searched for what does not change: the `cwd`, the
  /// `workdir`, and the headers of a patch.
  private static let directoryPattern = try? NSRegularExpression(
    pattern: #"\\?"(?:cwd|workdir)\\?"\s*:\s*\\?"(/[^"\\]*)"#)
  private static let patchPattern = try? NSRegularExpression(
    pattern: #"\*\*\* (?:Update|Add|Delete) File: (.+?)(?:\\n|\n|\\"|"|$)"#)

  static func readCodex(line: Data, into state: inout FileProgress) {
    let text = String(decoding: line, as: UTF8.self)
    let range = NSRange(text.startIndex..., in: text)
    for match in directoryPattern?.matches(in: text, range: range) ?? [] {
      guard let captured = Range(match.range(at: 1), in: text) else { continue }
      let directory = String(text[captured])
      state.activity.workingDirectories.insert(directory)
      state.lastDirectory = directory
    }
    for match in patchPattern?.matches(in: text, range: range) ?? [] {
      guard let captured = Range(match.range(at: 1), in: text) else { continue }
      let path = String(text[captured]).trimmingCharacters(in: .whitespaces)
      guard !path.isEmpty else { continue }
      if path.hasPrefix("/") {
        state.activity.editedPaths.insert(path)
      } else if let base = state.lastDirectory {
        state.activity.editedPaths.insert((base as NSString).appendingPathComponent(path))
      }
    }
  }
}
