import SwiftUI
import VibeApplication
import VibeDomain

/// What one repository's state reads as, in words: counts, distance from upstream, an operation
/// left half done, who else works there, and what went wrong. Kept apart from the view so that
/// the wording can be held to by tests.
struct RepositoryStatusPresentation: Equatable {
  let summary: String
  let details: [String]
  /// "Shared with Fix login", also in `details`.
  let sharedWith: String?
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
      summary = String(
        localized: "Reading…", bundle: .module, comment: "A repository whose state is being read.")
    } else {
      summary = Self.notReadYet
    }
    let others = state.sharedWith.compactMap { sessionNames[$0] }
    if !others.isEmpty {
      let shared = String(
        localized: "Shared with \(others.joined(separator: ", "))", bundle: .module,
        comment: "The names of the other sessions working in the same repository.")
      details.append(shared)
      sharedWith = shared
    } else {
      sharedWith = nil
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
    guard !counts.isEmpty else {
      return String(
        localized: "No changes", bundle: .module, comment: "A repository's working tree is clean.")
    }
    var parts: [String] = []
    if counts.conflicted > 0 {
      parts.append(
        String(
          localized: "\(counts.conflicted) conflicted", bundle: .module,
          comment: "A number of conflicted files."))
    }
    if counts.staged > 0 {
      parts.append(
        String(
          localized: "\(counts.staged) staged", bundle: .module,
          comment: "A number of staged files."))
    }
    if counts.unstaged > 0 {
      parts.append(
        String(
          localized: "\(counts.unstaged) unstaged", bundle: .module,
          comment: "A number of files changed and not staged."))
    }
    if counts.untracked > 0 {
      parts.append(
        String(
          localized: "\(counts.untracked) untracked", bundle: .module,
          comment: "A number of untracked files."))
    }
    var text = parts.joined(separator: " · ")
    // Only what the list actually holds is attributed: past the limit, nothing is claimed.
    if unattributed > 0, !status.isTruncated {
      text +=
        " — "
        + (unattributed == status.entries.count
          ? String(localized: "none in this session's transcript", bundle: .module)
          : String(
            localized: "\(unattributed) not in this session's transcript", bundle: .module))
    }
    return text
  }

  static func distance(ahead: Int, behind: Int) -> String {
    var parts: [String] = []
    if ahead > 0 { parts.append(Self.ahead(ahead)) }
    if behind > 0 { parts.append(Self.behind(behind)) }
    return String(
      localized: "\(parts.joined(separator: ", ")) of upstream", bundle: .module,
      comment: "How far a branch is from its upstream: “2 ahead, 1 behind”.")
  }

  static func ahead(_ count: Int) -> String {
    String(
      localized: "\(count) ahead", bundle: .module,
      comment: "A number of commits the branch has and its upstream has not.")
  }

  static func behind(_ count: Int) -> String {
    String(
      localized: "\(count) behind", bundle: .module,
      comment: "A number of commits the upstream has and the branch has not.")
  }

  static var notReadYet: String {
    String(
      localized: "Not read yet", bundle: .module,
      comment: "A repository whose state has not been read.")
  }

  static func sentence(for operation: RepositoryOperation) -> String {
    switch operation {
    case .merging: return String(localized: "Merge in progress", bundle: .module)
    case .rebasing: return String(localized: "Rebase in progress", bundle: .module)
    case .cherryPicking: return String(localized: "Cherry-pick in progress", bundle: .module)
    case .reverting: return String(localized: "Revert in progress", bundle: .module)
    case .bisecting: return String(localized: "Bisect in progress", bundle: .module)
    }
  }
}
