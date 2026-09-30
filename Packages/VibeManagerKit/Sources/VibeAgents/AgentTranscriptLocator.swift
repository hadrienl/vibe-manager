import Foundation

/// Finds the transcripts a session's CLI wrote, without opening them.
///
/// Claude Code writes `projects/<folder>/<session id>.jsonl`, and one file per sub-agent under
/// `<session id>/subagents/`. Codex writes `sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`.
public struct AgentTranscriptLocator: Sendable {
  public typealias ListDirectory = @Sendable (URL) -> [URL]?

  public let claudeProjects: URL
  public let codexSessions: URL
  /// Lists a folder; `nil` when it cannot be read. Injected so that tests can count the listings.
  let list: ListDirectory

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory(),
    list: @escaping ListDirectory = AgentTranscriptLocator.contents(of:)
  ) {
    self.claudeProjects = claudeProjects
    self.codexSessions = codexSessions
    self.list = list
  }

  @Sendable public static func contents(of folder: URL) -> [URL]? {
    try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  }

  public func claudeTranscripts(for identifier: String) -> [URL] {
    let manager = FileManager.default
    guard let folders = list(claudeProjects) else { return [] }
    var found: [URL] = []
    for folder in folders {
      let main = folder.appendingPathComponent("\(identifier).jsonl")
      guard manager.fileExists(atPath: main.path) else { continue }
      found.append(main)
      found.append(contentsOf: claudeSubagents(of: main, identifier: identifier))
    }
    return found
  }

  /// The sub-agents of the conversation whose file is `main`: in `<id>/subagents/` beside it.
  public func claudeSubagents(of main: URL, identifier: String) -> [URL] {
    let subagents = main.deletingLastPathComponent().appendingPathComponent(identifier)
      .appendingPathComponent("subagents")
    return (list(subagents) ?? []).filter { $0.pathExtension == "jsonl" }
  }

  /// Only the days the session can have written in are listed, from the day before it was
  /// created: a Codex home holds months of rollouts.
  public func codexRollouts(for identifier: String, since created: Date, until now: Date = Date())
    -> [URL]
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var day = calendar.startOfDay(for: created.addingTimeInterval(-86_400))
    let today = calendar.startOfDay(for: now)
    var found: [URL] = []
    while day <= today {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let folder =
        codexSessions
        .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
      if let files = list(folder) {
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
}
