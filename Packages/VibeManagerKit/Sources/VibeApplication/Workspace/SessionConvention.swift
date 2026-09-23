import Foundation
import VibeDomain

/// The convention a session runs under, written for its agent.
///
/// Pure — a session in, a text out — so every wording is covered by a test that needs no Git, no
/// disk and no CLI. The same text goes to every provider, in the prompt rather than in a system
/// prompt only one of them has: two texts would be two behaviours to test, and a system prompt is
/// something the user cannot read before it is sent in their name.
public struct SessionConventionBuilder: Sendable {
  /// Ends a convention sent without a prompt. Without it an agent handed only the convention
  /// would invent a task out of it.
  public static let holdSentence = "Do not start working yet: wait for my next instruction."

  public init() {}

  /// Whether this session has anything to coordinate. A single repository worked in place — the
  /// session as #7 made it — has not, and gets no block at all.
  public func applies(to session: WorkSession) -> Bool {
    applies(to: session.repositories)
  }

  public func applies(to repositories: [RepositoryContext]) -> Bool {
    guard let first = repositories.first else { return false }
    return repositories.count > 1 || first.mode == .worktree
  }

  /// - Parameter summarized: the list of repositories cut down to the main one and the names of
  ///   the others, for a prompt that would not fit otherwise. The user's prompt is theirs; the
  ///   convention is plumbing, and it is the convention that shrinks.
  /// - Parameter missing: repositories a verification found gone. They stay listed — the agent
  ///   would otherwise learn nothing of them — but as places not to work in.
  public func callAsFunction(
    for session: WorkSession,
    summarized: Bool = false,
    missing: Set<RepositoryID> = []
  ) -> String? {
    text(for: session.repositories, slug: session.slug, summarized: summarized, missing: missing)
  }

  public func text(
    for repositories: [RepositoryContext],
    slug: SessionSlug?,
    summarized: Bool = false,
    missing: Set<RepositoryID> = []
  ) -> String? {
    guard applies(to: repositories) else { return nil }
    let branch = slug?.branchName

    let count = repositories.count
    var blocks: [String] = [
      count == 1
        ? "Vibe Manager runs this session in one repository, under one convention."
        : "Vibe Manager runs this session across \(count) repositories, under one convention."
    ]

    var rules: [String] = []
    if let branch {
      rules.append(
        count == 1
          ? "Branch: \(branch)."
          : "Branch: \(branch) — the same name in every repository.")
    } else {
      rules.append("Each repository stays on the branch named below.")
    }
    rules.append("Work in the paths listed below, never in the original clones.")
    blocks.append(rules.joined(separator: "\n"))

    if summarized, let main = repositories.first, count > 1 {
      let others = repositories.dropFirst().map(\.displayName).joined(separator: ", ")
      blocks.append(
        line(for: main, missing: missing)
          + "\n- and \(count - 1) more, attached the same way: \(others).")
    } else {
      blocks.append(
        repositories.map { line(for: $0, missing: missing) }.joined(separator: "\n"))
    }

    if let branch {
      blocks.append(
        """
        If you need another branch, create it from \(branch) and give it the same name in every \
        repository. Never delete a branch or a worktree: Vibe Manager does not, and neither \
        should you.
        """)
    } else {
      blocks.append(
        "Never delete a branch or a worktree: Vibe Manager does not, and neither should you.")
    }
    return blocks.joined(separator: "\n\n")
  }

  /// What a session that is already running is told about a repository added to it.
  public func addendum(for repository: RepositoryContext, slug: SessionSlug?) -> String {
    var text = "Vibe Manager attached one more repository to this session:\n"
    text += line(for: repository)
    if let branch = slug?.branchName, repository.mode == .worktree {
      text += "\nIt follows the same convention: work on \(branch), in the path above."
    }
    // The running process was started without it among its folders: say so rather than let the
    // agent find out through a refusal.
    text +=
      "\nYou were started before it was attached: if you cannot write there, ask me for access."
    return text
  }

  private func line(for repository: RepositoryContext, missing: Set<RepositoryID> = []) -> String {
    if missing.contains(repository.id) {
      return "- \(repository.rootPath)\n  missing from the disk right now — do not work in it."
    }
    if let failure = repository.failure {
      return "- \(repository.rootPath)\n  not prepared (\(failure.message)) — do not work in it."
    }
    switch repository.mode {
    case .worktree:
      let path = repository.worktreePath ?? repository.rootPath
      var detail = "worktree of \(repository.rootPath)"
      if let branch = repository.branchName { detail += ", on \(branch)" }
      if let base = repository.baseRevision { detail += " (from \(base.prefix(7)))" }
      return "- \(path)\n  \(detail)."
    case .inPlace:
      let branch = repository.branchName.map { ", on \($0)" } ?? ""
      return "- \(repository.rootPath)\n  attached in place\(branch)."
    case .plainFolder:
      return "- \(repository.rootPath)\n  a plain folder, without Git."
    }
  }
}

/// Where an agent is started for a session, and what it is told about the rest.
public struct SessionLaunchContext: Hashable, Sendable {
  /// The main repository's effective path: its worktree if it has one, its clone otherwise. The
  /// session folder is not chosen: a repository attached in place lives elsewhere, and the
  /// agent would start in a folder holding only part of the work.
  public let workingDirectoryPath: String
  /// Every other repository the agent may read and write, handed over as `--add-dir`.
  public let additionalWorkingDirectoryPaths: [String]
  /// `VIBE_SESSION_SLUG`, `VIBE_SESSION_BRANCH`, `VIBE_SESSION_ROOT` — what the user's own
  /// scripts and hooks read to name a merge request or a build folder.
  public let environment: [String: String]
  public let convention: String?
  public let summarizedConvention: String?
  /// Repositories attached to the session that this launch leaves out.
  public let leftOut: [RepositoryContext]

  public static let slugVariable = "VIBE_SESSION_SLUG"
  public static let branchVariable = "VIBE_SESSION_BRANCH"
  public static let rootVariable = "VIBE_SESSION_ROOT"

  public enum Problem: Error, Hashable, Sendable {
    case noRepository
    case mainRepositoryUnavailable(RepositoryContext)
  }

  /// - Parameters:
  ///   - worktreeRootPath: where the session's folder is, for `VIBE_SESSION_ROOT`.
  ///   - excluding: repositories found missing by a verification, left out of this launch.
  public static func make(
    for session: WorkSession,
    worktreeRootPath: String?,
    excluding: Set<RepositoryID> = [],
    conventions: SessionConventionBuilder = SessionConventionBuilder()
  ) throws(Problem) -> SessionLaunchContext {
    guard let main = session.repositories.first else { throw .noRepository }
    guard !excluding.contains(main.id), let mainPath = main.effectivePath else {
      throw .mainRepositoryUnavailable(main)
    }

    var additional: [String] = []
    var leftOut: [RepositoryContext] = []
    for repository in session.repositories.dropFirst() {
      guard !excluding.contains(repository.id), let path = repository.effectivePath else {
        leftOut.append(repository)
        continue
      }
      if path != mainPath, !additional.contains(path) { additional.append(path) }
    }

    var environment: [String: String] = [:]
    if let slug = session.slug {
      environment[slugVariable] = slug.rawValue
      environment[branchVariable] = slug.branchName
    }
    if let folder = session.worktreeFolderPath {
      // Where the worktrees really are, which the current root no longer says if the setting
      // changed since they were made.
      environment[rootVariable] = folder
    } else if let slug = session.slug, let worktreeRootPath,
      session.repositories.contains(where: { $0.mode == .worktree })
    {
      environment[rootVariable] = (worktreeRootPath as NSString).appendingPathComponent(
        slug.rawValue)
    } else {
      environment[rootVariable] = mainPath
    }

    return SessionLaunchContext(
      workingDirectoryPath: mainPath,
      additionalWorkingDirectoryPaths: additional,
      environment: environment,
      convention: conventions(for: session, missing: excluding),
      summarizedConvention: conventions(for: session, summarized: true, missing: excluding),
      leftOut: leftOut
    )
  }

  /// The prompt the agent is started with: the convention first, then what the user wrote.
  ///
  /// Without a prompt of their own, the convention is sent alone and closed by a sentence that
  /// keeps the agent from starting on anything. When the whole does not fit in `byteLimit`, the
  /// list of repositories is summarised before the user's prompt is touched — and then left to
  /// the provider to refuse, as it would any prompt too long.
  public func prompt(
    with userPrompt: String?,
    byteLimit: Int = AgentPromptLimits.argumentByteLimit
  ) -> String? {
    let trimmed = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let convention else { return trimmed.isEmpty ? nil : userPrompt }
    let body = trimmed.isEmpty ? SessionConventionBuilder.holdSentence : (userPrompt ?? "")
    let full = convention + "\n\n" + body
    guard full.utf8.count > byteLimit, let summarizedConvention else { return full }
    return summarizedConvention + "\n\n" + body
  }

  public func request(
    modelID: String?,
    prompt: String?,
    resume: AgentResumeRequest = .none
  ) -> AgentLaunchRequest {
    AgentLaunchRequest(
      workingDirectoryPath: workingDirectoryPath,
      modelID: modelID,
      initialPrompt: prompt,
      resume: resume,
      additionalEnvironment: environment,
      additionalWorkingDirectoryPaths: additionalWorkingDirectoryPaths
    )
  }
}
