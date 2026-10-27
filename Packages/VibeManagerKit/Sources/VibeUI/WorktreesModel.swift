import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Settings › Worktrees (#432): where the agents create the worktrees of their tasks.
@MainActor
@Observable
public final class WorktreesModel {
  @ObservationIgnored private let preferences: any WorktreeLocationPreferences

  public var settings: WorktreeLocationSettings {
    didSet {
      guard settings != oldValue else { return }
      preferences.worktreeLocations = settings
    }
  }

  public init(preferences: any WorktreeLocationPreferences = InMemoryWorktreeLocationPreferences())
  {
    self.preferences = preferences
    settings = preferences.worktreeLocations
  }

  /// The main repositories of `sessions`, each once, by name.
  static func repositories(of sessions: [WorkSession]) -> [String] {
    let paths = Set(sessions.compactMap(WorktreeInstructions.mainRepository(of:)))
    return paths.sorted {
      let names = (($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent)
      return names.0.localizedStandardCompare(names.1) == .orderedAscending
    }
  }
}

/// A repository and a task the preview resolves the path for.
struct WorktreeLocationExample: Hashable {
  let repository: String
  let branch: String
  let ticket: String
  let session: String
  let agent: String

  var label: String {
    "#\(ticket) · \((repository as NSString).lastPathComponent)"
  }

  func values(on date: Date = Date()) -> [WorktreeLocation.Variable: String] {
    [
      .repository: Self.abbreviated(repository),
      .project: (repository as NSString).lastPathComponent,
      .branch: branch, .ticket: ticket, .session: session, .agent: agent,
      .date: date.formatted(.iso8601.year().month().day()),
    ]
  }

  /// Two tasks: on the repositories given, the first two, or on made-up ones.
  static func examples(repositories: [String]) -> [WorktreeLocationExample] {
    let first = repositories.first ?? (NSHomeDirectory() as NSString).appendingPathComponent(
      "Developer/my-app")
    let second =
      repositories.dropFirst().first
      ?? (NSHomeDirectory() as NSString).appendingPathComponent("Developer/api")
    return [
      WorktreeLocationExample(
        repository: first, branch: "fix-430-update-banner", ticket: "430",
        session: "update-banner", agent: "claude-code"),
      WorktreeLocationExample(
        repository: second, branch: "feat-1315-search", ticket: "1315", session: "search",
        agent: "codex"),
    ]
  }

  static func abbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
