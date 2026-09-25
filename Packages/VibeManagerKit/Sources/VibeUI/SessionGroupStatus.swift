import Foundation
import VibeApplication

/// What the header of a group says about its sessions, folded or not (#27).
public struct SessionGroupSummary: Equatable, Sendable {
  /// The most pressing state among the sessions, with the symbol and the words of the row that
  /// has it. `nil` when none of them has anything to say: all closed, finished or archived.
  public let headline: SessionStatusPresentation?
  /// Waiting for the user: a question, a permission, an answer not read.
  public let needsAttentionCount: Int
  /// Ended badly, or whose agent went missing.
  public let errorCount: Int
  public let workingCount: Int

  public init(
    headline: SessionStatusPresentation?,
    needsAttentionCount: Int = 0,
    errorCount: Int = 0,
    workingCount: Int = 0
  ) {
    self.headline = headline
    self.needsAttentionCount = needsAttentionCount
    self.errorCount = errorCount
    self.workingCount = workingCount
  }
}

/// Folds the states of a group's sessions into the one its header shows.
///
/// A symbol and a sentence, never a colour alone: three dots of different colours say nothing to
/// someone who cannot tell them apart.
public enum SessionGroupStatus {
  /// Most urgent first. What only the user can unblock comes before an error: a question stops the
  /// agent until it is answered, where an ended process has already stopped and can wait.
  ///
  /// "Agent unavailable" wears the severity of an attention without being one, so the order reads
  /// what the agent is doing rather than the severity alone.
  static func rank(_ status: SessionStatusPresentation) -> Int? {
    if status.needsAttention {
      switch status.agentActivity {
      case .awaitingUser(.question): return 0
      case .awaitingUser(.approval): return 1
      default: return 2
      }
    }
    switch status.severity {
    case .error: return 3
    case .attention: return 4
    case .normal, .active: break
    }
    if status.agentActivity == .working { return 5 }
    if status.isStarting { return 6 }
    if status.agentActivity == .idle { return 7 }
    return nil
  }

  public static func aggregate(_ statuses: [SessionStatusPresentation]) -> SessionGroupSummary {
    var headline: (rank: Int, status: SessionStatusPresentation)?
    for status in statuses {
      guard let rank = rank(status) else { continue }
      if headline.map({ rank < $0.rank }) ?? true {
        headline = (rank, status)
      }
    }
    return SessionGroupSummary(
      headline: headline?.status,
      needsAttentionCount: statuses.filter(\.needsAttention).count,
      errorCount: statuses.filter { status in
        let rank = rank(status)
        return rank == 3 || rank == 4
      }.count,
      workingCount: statuses.filter { $0.agentActivity == .working }.count
    )
  }

  /// What VoiceOver reads for a header: "vibe-manager, 3 sessions, 1 needs attention, 1 working,
  /// collapsed".
  public static func accessibilityLabel(
    for group: SessionGroup,
    summary: SessionGroupSummary,
    isExpanded: Bool,
    containsSelection: Bool
  ) -> String {
    var parts = [
      group.id == nil
        ? String(
          localized: "No Folder", bundle: .module,
          comment: "The group of the sessions that have no working folder.")
        : group.title
    ]
    if group.isRenamed { parts.append(group.folderName) }
    parts.append(
      String(
        localized: "\(group.sessions.count) sessions", bundle: .module,
        comment: "How many sessions a group of the sidebar holds."))
    if summary.needsAttentionCount > 0 {
      parts.append(
        String(
          localized: "\(summary.needsAttentionCount) need attention", bundle: .module,
          comment: "How many sessions of a group wait for the user."))
    }
    if summary.errorCount > 0 {
      parts.append(
        String(
          localized: "\(summary.errorCount) with an error", bundle: .module,
          comment: "How many sessions of a group ended badly or lost their agent."))
    }
    if summary.workingCount > 0 {
      parts.append(
        String(
          localized: "\(summary.workingCount) working", bundle: .module,
          comment: "How many sessions of a group have an agent at work."))
    }
    if group.isMissing {
      parts.append(
        String(
          localized: "Folder not found", bundle: .module,
          comment: "The working folder of a group has been moved or deleted."))
    }
    if containsSelection {
      parts.append(
        String(
          localized: "Contains the selected session", bundle: .module,
          comment: "Read out by VoiceOver on a folded group."))
    }
    parts.append(
      isExpanded
        ? String(localized: "Expanded", bundle: .module, comment: "A group of the sidebar.")
        : String(localized: "Collapsed", bundle: .module, comment: "A group of the sidebar."))
    return parts.joined(separator: ", ")
  }
}
