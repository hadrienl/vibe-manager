import Foundation
import VibeDomain

/// Settings › Worktrees (#432): a preference of this Mac.
@MainActor
public protocol WorktreeLocationPreferences: AnyObject {
  var worktreeLocations: WorktreeLocationSettings { get set }
}

@MainActor
public final class InMemoryWorktreeLocationPreferences: WorktreeLocationPreferences {
  public var worktreeLocations: WorktreeLocationSettings

  public init(_ settings: WorktreeLocationSettings = WorktreeLocationSettings()) {
    worktreeLocations = settings
  }
}

/// What an agent is told of where to create its worktrees (#432), on top of the instructions it is
/// already given. Vibe Manager creates nothing in git: the agent does, at this path.
public enum WorktreeInstructions {
  /// `nil` when the path is empty: the agents choose where.
  ///
  /// The variables Vibe Manager knows for this session are resolved; the branch and the ticket are
  /// the agent's to fill, as it names the branch. A coordinator creates worktrees for children of
  /// other repositories and tickets: only the agent and the date are resolved for it.
  public static func text(
    for session: WorkSession, agent: AgentProviderID, settings: WorktreeLocationSettings,
    now: Date = Date()
  ) -> String? {
    let repository = mainRepository(of: session)
    let location = settings.location(for: repository)
    guard !location.isEmpty else { return nil }
    var values: [WorktreeLocation.Variable: String] = [
      .agent: agent.rawValue, .date: day(now),
    ]
    let isCoordinator = session.coordination?.isCoordinator == true
    if !isCoordinator {
      if let repository {
        values[.repository] = repository
        values[.project] = (repository as NSString).lastPathComponent
      }
      if let number = session.ticket?.url?.lastPathComponent, Int(number) != nil {
        values[.ticket] = number
      }
      let name = WorktreeLocation.folderName(session: session.name)
      if !name.isEmpty { values[.session] = name }
    }
    var lines = [
      "Where to create git worktrees: whenever you create a git worktree — for your own work or, "
        + "as a coordinator, for a child session — create it at `\(location.resolved(values))`.",
      "Fill in what is left in braces: {branch} is the worktree's branch with every / replaced by "
        + "-; {ticket} is the number of the ticket the task works on, or else {branch}; {session} "
        + "is the task's name in lower case, words joined by -; {repo} is the folder of the main "
        + "repository (not of one of its worktrees) and {project} that folder's name.",
    ]
    if location.isInsideRepository {
      lines.append(
        "When that path is inside the repository, add it to the repository's .git/info/exclude "
          + "(once) so that it stays out of git status.")
    }
    if isCoordinator, !settings.exceptions.isEmpty {
      lines.append("These repositories use their own path instead:")
      for (path, exception) in settings.exceptions.sorted(by: { $0.key < $1.key }) {
        lines.append("- \(path): `\(exception.template)`")
      }
    }
    lines.append("This applies to new worktrees only: never move one that already exists.")
    return lines.joined(separator: "\n")
  }

  /// The folder of the main repository the session works in: the one a worktree belongs to.
  public static func mainRepository(of session: WorkSession) -> String? {
    guard let context = session.repositories.first else { return nil }
    let folder = context.git?.repositoryRootPath ?? context.path
    return mainRepository(of: folder)
  }

  /// A worktree's `.git` is a file, `gitdir: <main>/.git/worktrees/<name>`.
  public static func mainRepository(of folder: String) -> String {
    let folder = (folder as NSString).standardizingPath
    let dotGit = (folder as NSString).appendingPathComponent(".git")
    guard let content = try? String(contentsOfFile: dotGit, encoding: .utf8),
      content.hasPrefix("gitdir:")
    else { return folder }
    var gitDirectory = content.dropFirst("gitdir:".count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // `worktree.useRelativePaths` writes it relative to the worktree.
    if !gitDirectory.hasPrefix("/") {
      gitDirectory = (folder as NSString).appendingPathComponent(gitDirectory)
    }
    gitDirectory = (gitDirectory as NSString).standardizingPath
    guard let range = gitDirectory.range(of: "/.git/worktrees/", options: .backwards) else {
      return folder
    }
    return String(gitDirectory[..<range.lowerBound])
  }

  /// `2026-10-27`, in the Mac's time zone.
  public static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
