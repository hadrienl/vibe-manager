import SwiftUI
import VibeApplication
import VibeDomain

/// What one repository's state reads as, in words: counts, distance from upstream, an operation
/// left half done, who else works there, and what went wrong. Kept apart from the view so that
/// the wording can be held to by tests.
struct RepositoryStatusPresentation: Equatable {
  let summary: String
  let details: [String]
  let issue: String?
  let suggestion: String?
  let command: String?
  let isStale: Bool

  init(state: RepositoryStatusState, sessionNames: [SessionID: String] = [:]) {
    var details: [String] = []
    if let status = state.lastValid {
      summary = Self.summary(of: status, unattributed: state.unattributedCount)
      if let ahead = status.branch.ahead, let behind = status.branch.behind,
        ahead > 0 || behind > 0
      {
        details.append(Self.distance(ahead: ahead, behind: behind))
      }
      if let operation = status.operation {
        details.append(Self.sentence(for: operation))
      }
    } else if case .refreshing = state.phase {
      summary = "Reading…"
    } else {
      summary = "Not read yet"
    }
    let others = state.sharedWith.compactMap { sessionNames[$0] }
    if !others.isEmpty {
      details.append("Shared with \(others.joined(separator: ", "))")
    }
    self.details = details

    switch state.phase {
    case .failed(let issue, _):
      self.issue = issue.message
      suggestion = issue.suggestion
      command = issue.copyableCommand
      isStale = true
    case .unobserved:
      issue = nil
      suggestion = nil
      command = nil
      isStale = true
    case .fresh, .refreshing:
      issue = nil
      suggestion = nil
      command = nil
      isStale = false
    }
  }

  static func summary(of status: WorkingTreeStatus, unattributed: Int) -> String {
    let counts = status.counts
    guard !counts.isEmpty else { return "No changes" }
    var parts: [String] = []
    if counts.conflicted > 0 { parts.append("\(counts.conflicted) conflicted") }
    if counts.staged > 0 { parts.append("\(counts.staged) staged") }
    if counts.unstaged > 0 { parts.append("\(counts.unstaged) unstaged") }
    if counts.untracked > 0 { parts.append("\(counts.untracked) untracked") }
    var text = parts.joined(separator: " · ")
    // Only what the list actually holds is attributed: past the limit, nothing is claimed.
    if unattributed > 0, !status.isTruncated {
      text +=
        unattributed == status.entries.count
        ? " — none in this session's transcript"
        : " — \(unattributed) not in this session's transcript"
    }
    return text
  }

  static func distance(ahead: Int, behind: Int) -> String {
    var parts: [String] = []
    if ahead > 0 { parts.append("\(ahead) ahead") }
    if behind > 0 { parts.append("\(behind) behind") }
    return parts.joined(separator: ", ") + " of upstream"
  }

  static func sentence(for operation: RepositoryOperation) -> String {
    switch operation {
    case .merging: return "Merge in progress"
    case .rebasing: return "Rebase in progress"
    case .cherryPicking: return "Cherry-pick in progress"
    case .reverting: return "Revert in progress"
    case .bisecting: return "Bisect in progress"
    }
  }
}

struct RepositoryStatusSummary: View {
  let state: RepositoryStatusState
  let sessionNames: [SessionID: String]

  var body: some View {
    // A lock held for minutes is not published again, since nothing about it changed but its age:
    // the sentence is rebuilt on a schedule so the age it says stays true.
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      content(RepositoryStatusPresentation(state: state, sessionNames: sessionNames))
    }
  }

  private func content(_ presentation: RepositoryStatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(presentation.summary)
        .font(.caption)
        .foregroundStyle(presentation.isStale ? .tertiary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(presentation.details, id: \.self) { detail in
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let issue = presentation.issue {
        Label(issue, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        if let suggestion = presentation.suggestion {
          Text(suggestion)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let command = presentation.command {
          // Selectable, to be copied: the application never runs it.
          Text(command)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
