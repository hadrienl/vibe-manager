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
/// Only read, never written, and read incrementally: a transcript grows to megabytes and is read
/// again each time it grows, so each file is resumed where the last reading stopped.
public actor AgentTranscriptReader: SessionTranscriptSource {
  /// Where each conversation's files were found: the conversation view's memory, shared (#276).
  /// The report reads the transcript every second while the agent writes; listing every folder
  /// of `~/.claude/projects`, or one folder per day of a Codex session, each time would cost more
  /// than reading what the files gained.
  private let locations: TranscriptLocationCache
  private var locator: AgentTranscriptLocator { locations.locator }
  private var progress: [String: FileProgress] = [:]

  struct FileProgress {
    var offset: UInt64 = 0
    var activity = TranscriptActivity()
    /// Codex names patched files relative to where the command ran.
    var lastDirectory: String?
  }

  public init(locations: TranscriptLocationCache) {
    self.locations = locations
  }

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory(),
    list: @escaping AgentTranscriptLocator.ListDirectory = AgentTranscriptLocator.contents(of:),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      locations: TranscriptLocationCache(
        locator: AgentTranscriptLocator(
          claudeProjects: claudeProjects, codexSessions: codexSessions, list: list),
        now: now))
  }

  /// Every conversation the session has had is read, not only the current one: after a switch of
  /// agent, what the previous one edited and where it worked is still this session's work.
  public func activity(for session: WorkSession) async -> TranscriptActivity? {
    var activity = TranscriptActivity()
    var foundAny = false
    for conversation in session.conversations {
      guard let found = locations.transcripts(of: conversation, in: session) else { continue }
      for file in found.files {
        foundAny = true
        let read = advance(file, isCodex: found.isCodex)
        activity.editedPaths.formUnion(read.editedPaths)
        activity.workingDirectories.formUnion(read.workingDirectories)
      }
    }
    return foundAny ? activity : nil
  }

  /// The folders to watch for the session's transcripts to grow: the whole Claude Code projects
  /// folder, the whole Codex sessions folder, or both after a switch between them.
  ///
  /// Not the folders its files are in today. A Claude Code session selected before its agent wrote
  /// a word has no file yet, so no folder; a Codex session writes in the folder of the day, which
  /// changes at midnight and when it is resumed the next day. Either would stop being watched
  /// exactly when it starts to matter. Events from other sessions' transcripts wake the monitor for
  /// a comparison of names, nothing more: only files named after this session count.
  public func transcriptDirectories(for session: WorkSession) async -> [String] {
    var directories: [String] = []
    for conversation in session.conversations where Self.identifier(of: conversation) != nil {
      let found: [URL]
      switch conversation.transcriptProviderID {
      case ClaudeCodeAgentProvider.id.rawValue:
        found = locator.allClaudeProjects
      case CodexAgentProvider.id.rawValue:
        found = locator.allCodexSessions
      default:
        continue
      }
      for directory in found.map(\.path) where !directories.contains(directory) {
        directories.append(directory)
      }
    }
    return directories
  }

  private static func identifier(of conversation: SessionAgentConfiguration) -> String? {
    guard
      let identifier = conversation.resumeIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !identifier.isEmpty
    else { return nil }
    return identifier
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
