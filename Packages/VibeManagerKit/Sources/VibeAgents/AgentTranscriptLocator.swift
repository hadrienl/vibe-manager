import Foundation
import VibeApplication

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
  /// The folders of the extra accounts, each its account's conversations' (#478).
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
  public var allClaudeProjects: [URL] {
    Self.all(own: claudeProjects, accounts: homes?.claudeProjects)
  }
  /// Every folder a Codex conversation can be in, the agent's own first.
  public var allCodexSessions: [URL] {
    Self.all(own: codexSessions, accounts: homes?.codexSessions)
  }

  /// The folders a conversation of the agent `providerID` is looked for in.
  public func claudeProjects(of providerID: String?) -> [URL] {
    Self.folders(of: providerID, own: claudeProjects, accounts: homes?.claudeProjects)
  }

  /// The folders a conversation of the agent `providerID` is looked for in.
  public func codexSessions(of providerID: String?) -> [URL] {
    Self.folders(of: providerID, own: codexSessions, accounts: homes?.codexSessions)
  }

  /// An extra account's conversations are in its folder, and only there: a folder copied to start
  /// an account holds the agent's conversations too, which are not the account's — read from both,
  /// they would be added up twice (#478). The agent's own, and its endpoints', are in its folder. An
  /// account removed since has no known folder: every one is looked through.
  private static func folders(of providerID: String?, own: URL, accounts: [String: URL]?)
    -> [URL]
  {
    guard let providerID, AgentProviderID(providerID).isAccount else { return [own] }
    return accounts?[providerID].map { [$0] } ?? all(own: own, accounts: accounts)
  }

  private static func all(own: URL, accounts: [String: URL]?) -> [URL] {
    [own] + (accounts ?? [:]).sorted { $0.key < $1.key }.map(\.value)
  }

  @Sendable public static func contents(of folder: URL) -> [URL]? {
    try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  }

  /// In the folders of the conversation's agent, `claudeProjects(of:)`. Should several hold it —
  /// an account removed, looked for everywhere — only the one that wrote last counts. Within a
  /// home, a conversation resumed from another project has two files, and both count.
  public func claudeTranscripts(for identifier: String, providerID: String? = nil) -> [URL] {
    let manager = FileManager.default
    var found: [URL] = []
    var newest: Date?
    for projects in claudeProjects(of: providerID) {
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
  public func codexRollouts(
    for identifier: String, providerID: String? = nil, since created: Date,
    until now: Date = Date()
  ) -> [URL] {
    codexRollouts(
      for: identifier, providerID: providerID, fromDay: created.addingTimeInterval(-86_400),
      until: now)
  }

  /// The rollouts of the conversation in the day folders from `fromDay`'s through `now`'s, in the
  /// folders of its agent, `codexSessions(of:)`: the one walk through Codex's days, shared with
  /// `TranscriptLocationCache`.
  public func codexRollouts(
    for identifier: String, providerID: String? = nil, fromDay first: Date, until now: Date
  ) -> [URL] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var day = calendar.startOfDay(for: first)
    let today = calendar.startOfDay(for: now)
    var found: [URL] = []
    let roots = codexSessions(of: providerID)
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
    // The same rollout in two homes — an account removed, looked for everywhere, whose folder was
    // copied from another —: the one written last.
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
