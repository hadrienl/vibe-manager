import Foundation

/// Finds the transcripts a session's CLI wrote, without opening them.
///
/// Claude Code writes `projects/<folder>/<session id>.jsonl`, and one file per sub-agent under
/// `<session id>/subagents/`. Codex writes `sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`.
public struct AgentTranscriptLocator: Sendable {
  public let claudeProjects: URL
  public let codexSessions: URL

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory()
  ) {
    self.claudeProjects = claudeProjects
    self.codexSessions = codexSessions
  }

  public func claudeTranscripts(for identifier: String) -> [URL] {
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
  public func codexRollouts(for identifier: String, since created: Date, until now: Date = Date())
    -> [URL]
  {
    let manager = FileManager.default
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
}
