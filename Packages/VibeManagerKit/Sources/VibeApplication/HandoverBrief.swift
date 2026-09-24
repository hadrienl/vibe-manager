import Foundation
import VibeDomain

/// What a handover summary is built from: the session, and what is known right now of where its
/// work stands.
///
/// The branch report and the Git states are optional: the summary is still written without them,
/// from the snapshots the session recorded, and says so.
public struct SessionBriefInput: Sendable {
  public let session: WorkSession
  public let branches: SessionBranchReport?
  public let statuses: [RepositoryStatusState]
  /// Display names of the agents, by provider identifier. An agent missing here is named by its
  /// identifier.
  public let agentNames: [String: String]
  /// The session's notes, which live apart from it.
  public let notes: String?

  public init(
    session: WorkSession,
    branches: SessionBranchReport? = nil,
    statuses: [RepositoryStatusState] = [],
    agentNames: [String: String] = [:],
    notes: String? = nil
  ) {
    self.session = session
    self.notes = notes
    self.branches = branches
    self.statuses = statuses
    self.agentNames = agentNames
  }
}

extension SessionContextBriefBuilder {
  /// The summary handed to the agent a session is switched to.
  ///
  /// Pure like the restart brief — the same input always gives the same text — and bounded by the
  /// same ceiling, with one difference: the prompt the session was created with is never dropped.
  /// The new agent is owed it, it already fitted when the session was created, and when the rest
  /// cannot make room for it the brief says by how much it is over instead of cutting it.
  public func handover(
    _ input: SessionBriefInput,
    to target: SessionAgentConfiguration
  ) -> SessionContextBrief {
    let session = input.session
    let changesProvider = session.agent.map { $0.providerID != target.providerID } ?? true

    let periods = agentPeriods(of: session)
    var agents = periods.isEmpty ? nil : agentLines(periods, names: input.agentNames)
    var notes = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    if notes?.isEmpty == true { notes = nil }
    var visited = input.branches.flatMap { $0.visitedOnly.isEmpty ? nil : $0.visitedOnly }
    var compactRepositories = false

    func parts() -> [(SessionContextBrief.Section, String)] {
      var parts: [(SessionContextBrief.Section, String)] = [(.heading, heading(of: session))]
      if let agents {
        parts.append((.agents, "Agents so far:\n" + agents.joined(separator: "\n")))
      }
      if let repositories = repositories(input, compact: compactRepositories) {
        parts.append(repositories)
      }
      if let visited {
        parts.append((.visited, "Also looked in: \(visited.joined(separator: ", "))"))
      }
      if let notes {
        parts.append((.notes, "Notes kept on this session:\n\(notes)"))
      }
      let prompt = session.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      if !prompt.isEmpty {
        parts.append(
          (.task, "The instruction this session was created with, for context:\n\(prompt)"))
      }
      parts.append((.instruction, Self.handoverInstruction))
      return parts
    }

    var isTruncated = false
    func assembled() -> String {
      var blocks = [changesProvider ? Self.handoverPreamble : Self.sameAgentPreamble]
      blocks.append(contentsOf: parts().map(\.1))
      if isTruncated { blocks.append(Self.handoverTruncationNotice) }
      return blocks.joined(separator: "\n\n")
    }

    // Given up whole and in this order: what the new agent can find again by itself goes first.
    let shortenings: [() -> Bool] = [
      {
        guard let lines = agents, lines.count > 1 else { return false }
        agents = Array(lines.suffix(1))
        return true
      },
      {
        guard notes != nil else { return false }
        notes = nil
        return true
      },
      {
        guard visited != nil else { return false }
        visited = nil
        return true
      },
      {
        guard !compactRepositories else { return false }
        compactRepositories = true
        return true
      },
    ]
    for shorten in shortenings {
      guard assembled().utf8.count > byteLimit else { break }
      if shorten() { isTruncated = true }
    }

    let text = assembled()
    return SessionContextBrief(
      text: text,
      isTruncated: isTruncated,
      includedSections: parts().map(\.0),
      overflowByteCount: max(0, text.utf8.count - byteLimit)
    )
  }

  // MARK: - Agents

  private struct AgentPeriod {
    let agent: SessionAgentConfiguration
    let from: Date
    let to: Date?
  }

  /// Who worked here, and when: one period per agent that actually ran, the current one last and
  /// open. A switch that failed started nothing, and one made before the session ever ran left an
  /// agent that never worked, so neither opens a period.
  private func agentPeriods(of session: WorkSession) -> [AgentPeriod] {
    guard let current = session.agent, session.hasEverStarted else { return [] }
    let completed = session.agentHistory.filter(\.leftAgentThatRan)
    var periods: [AgentPeriod] = []
    var agent = completed.first?.previous ?? current
    var start = session.startedAt ?? session.createdAt
    for change in completed {
      periods.append(AgentPeriod(agent: agent, from: start, to: change.date))
      agent = change.next
      start = change.date
    }
    periods.append(AgentPeriod(agent: current, from: start, to: nil))
    return periods
  }

  private func agentLines(_ periods: [AgentPeriod], names: [String: String]) -> [String] {
    periods.map { period in
      let label = Self.label(period.agent, names: names)
      let from = Self.date(period.from)
      guard let to = period.to else {
        return "- \(label), from \(from) until this handover"
      }
      return "- \(label), from \(from) to \(Self.date(to))"
    }
  }

  // MARK: - Repositories

  private func repositories(
    _ input: SessionBriefInput,
    compact: Bool
  ) -> (SessionContextBrief.Section, String)? {
    guard let report = input.branches, !report.repositories.isEmpty else {
      return folders(of: input.session).map { (.folders, $0) }
    }
    let lines = report.repositories.map { repository -> String in
      let status = input.statuses.first { $0.key.repositoryPath == repository.path }?.lastValid
      let branch =
        repository.checkedOutBranch ?? status?.branch.branchName
        ?? status?.branch.headRevision.map { "detached at \(String($0.prefix(7)))" }
      var line = "- \(repository.name) — \(repository.path)"
      if let branch { line += ", branch \(branch)" }
      guard !compact else { return line }

      if let change = repository.change, change.name == repository.checkedOutBranch {
        line += " (\(Self.describe(change)))"
      }
      if let status {
        let counts = status.counts
        let changed = counts.staged + counts.unstaged + counts.untracked + counts.conflicted
        line += changed == 0 ? ", clean" : ", \(changed) uncommitted \(Self.plural(changed))"
        if counts.conflicted > 0 { line += " (\(counts.conflicted) in conflict)" }
        if let operation = status.operation {
          line += ", \(Self.describe(operation)) in progress"
        }
      } else {
        line += repository.isDirty ? ", with uncommitted changes" : ", clean"
      }
      return line
    }
    let header = "Where the work is, read \(Self.date(report.readAt)):"
    return (.repositories, ([header] + lines).joined(separator: "\n"))
  }

  private static func describe(_ change: BranchChange) -> String {
    let commits = change.commitCount.map { $0 == 1 ? "1 commit" : "\($0) commits" }
    switch change.kind {
    case .created:
      return ["created in this session", commits.map { "\($0) since" }]
        .compactMap { $0 }.joined(separator: ", ")
    case .advanced:
      return commits.map { "moved forward by \($0) in this session" }
        ?? "moved forward in this session"
    case .rewritten:
      return "rewritten in this session"
    }
  }

  private static func describe(_ operation: RepositoryOperation) -> String {
    switch operation {
    case .merging: return "a merge"
    case .rebasing: return "a rebase"
    case .cherryPicking: return "a cherry-pick"
    case .reverting: return "a revert"
    case .bisecting: return "a bisect"
    }
  }

  private static func plural(_ count: Int) -> String {
    count == 1 ? "file" : "files"
  }

  // MARK: - Fixed text

  static let handoverPreamble = """
    You are taking over a session another coding agent was working in. Its conversation is not \
    available to you: nothing below comes from it. This is what Vibe Manager recorded about the \
    session.
    """

  static let sameAgentPreamble = """
    You are taking over a session an earlier conversation was working in. That conversation is \
    not available to you: nothing below comes from it. This is what Vibe Manager recorded about \
    the session.
    """

  static let handoverInstruction = """
    Continue from the current state of these files, on the branches and in the worktrees listed \
    above. Do not create new branches or worktrees unless asked. Read whatever you need rather \
    than trusting the details above: they were recorded earlier and may have moved since.
    """

  static let handoverTruncationNotice = "(This summary was shortened to fit.)"
}
