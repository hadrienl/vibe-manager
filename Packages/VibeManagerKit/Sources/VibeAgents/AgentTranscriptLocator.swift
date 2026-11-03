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
  /// The folders of the extra accounts, looked through after these two (#478).
  let homes: AgentHomes?

  public init(
    claudeProjects: URL = ClaudeCodeHome.projectsDirectory(),
    codexSessions: URL = CodexHome.sessionsDirectory(),
    homes: AgentHomes? = nil,
    list: @escaping ListDirectory = AgentTranscriptLocator.contents(of:)
  ) {
    self.claudeProjects = claudeProjects
    self.codexSessions = codexSessions
    self.homes = homes
    self.list = list
  }

  /// Every folder a Claude Code conversation can be in, the agent's own first.
  public var allClaudeProjects: [URL] { [claudeProjects] + (homes?.claudeProjects ?? []) }
  /// Every folder a Codex conversation can be in, the agent's own first.
  public var allCodexSessions: [URL] { [codexSessions] + (homes?.codexSessions ?? []) }

  @Sendable public static func contents(of folder: URL) -> [URL]? {
    try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  }

  /// A folder copied to start an account holds the same conversations: only the home that wrote
  /// last counts, or they would be read and added up twice. Within a home, a conversation resumed
  /// from another project has two files, and both count.
  public func claudeTranscripts(for identifier: String) -> [URL] {
    let manager = FileManager.default
    var found: [URL] = []
    var newest: Date?
    for projects in allClaudeProjects {
      let mains = (list(projects) ?? [])
        .map { $0.appendingPathComponent("\(identifier).jsonl") }
        .filter { manager.fileExists(atPath: $0.path) }
      guard let written = mains.map(Self.modificationDate(of:)).max() else { continue }
      if let newest, written <= newest { continue }
      newest = written
      found = mains.flatMap { [$0] + claudeSubagents(of: $0, identifier: identifier) }
    }
    return found
  }

  private static func modificationDate(of file: URL) -> Date {
    (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
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
    codexRollouts(for: identifier, fromDay: created.addingTimeInterval(-86_400), until: now)
  }

  /// The rollouts of the conversation in the day folders from `fromDay`'s through `now`'s: the
  /// one walk through Codex's days, shared with `TranscriptLocationCache`.
  public func codexRollouts(for identifier: String, fromDay first: Date, until now: Date) -> [URL] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var day = calendar.startOfDay(for: first)
    let today = calendar.startOfDay(for: now)
    var found: [URL] = []
    let roots = allCodexSessions
    while day <= today {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      for root in roots {
        let folder =
          root
          .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
          .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
          .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
        if let files = list(folder) {
          found.append(
            contentsOf: files.filter {
              $0.lastPathComponent.contains(identifier) && $0.pathExtension == "jsonl"
            })
        }
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    // The same rollout in two homes, a folder copied to start an account: the one written last.
    var kept: [String: URL] = [:]
    for file in found {
      if let other = kept[file.lastPathComponent],
        Self.modificationDate(of: file) <= Self.modificationDate(of: other)
      {
        continue
      }
      kept[file.lastPathComponent] = file
    }
    return found.filter { kept[$0.lastPathComponent] == $0 }
  }
}
