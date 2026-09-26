import VibeDomain

/// A command applied to several sessions at once (#77).
public enum SessionBatchAction: Equatable, Hashable, Sendable {
  case close
  case archive
  case unarchive
  case restart
  case move(to: SessionTaskStatus)
}

/// Why a session of the selection was left out of a command.
public enum SessionBatchSkip: Equatable, Hashable, Sendable {
  case alreadyClosed
  case alreadyArchived
  case notArchived
  case stillRunning
  case agentUnavailable
  /// A close or a restart of it is already under way.
  case busy
  case alreadyInStatus
  /// Restarting it would send a summary nobody has read: Restart, on its own, shows it first.
  case needsSummary
}

/// What became of one session of a batch.
public enum SessionBatchItemResult: Equatable, Sendable {
  case done
  /// Done, with something the user should still hear about: a process that did not answer.
  case doneWithWarning(message: String, suggestion: String?)
  case skipped(SessionBatchSkip)
  case failed(message: String, suggestion: String?)
}

/// Which sessions of a selection a command applies to, and why the others are left out.
///
/// A batch invents no rule of its own: a session is eligible exactly when the same command would
/// be offered for it alone. The caller hands in that answer, session by session.
public struct SessionBatchPlan: Equatable, Sendable {
  public let action: SessionBatchAction
  /// In the order given, which is the order the sidebar draws them.
  public let eligible: [SessionID]
  public let skipped: [SessionID: SessionBatchSkip]

  public init(
    action: SessionBatchAction, eligible: [SessionID], skipped: [SessionID: SessionBatchSkip]
  ) {
    self.action = action
    self.eligible = eligible
    self.skipped = skipped
  }

  public static func make(
    _ action: SessionBatchAction, ids: [SessionID], skip: (SessionID) -> SessionBatchSkip?
  ) -> SessionBatchPlan {
    var eligible: [SessionID] = []
    var skipped: [SessionID: SessionBatchSkip] = [:]
    var seen: Set<SessionID> = []
    for id in ids where seen.insert(id).inserted {
      if let reason = skip(id) {
        skipped[id] = reason
      } else {
        eligible.append(id)
      }
    }
    return SessionBatchPlan(action: action, eligible: eligible, skipped: skipped)
  }

  public var isEmpty: Bool { eligible.isEmpty }

  /// How many sessions were left out for each reason, in a stable order.
  public var skippedCounts: [(reason: SessionBatchSkip, count: Int)] {
    SessionBatchSkip.reportOrder.compactMap { reason in
      let count = skipped.values.filter { $0 == reason }.count
      return count > 0 ? (reason, count) : nil
    }
  }
}

extension SessionBatchSkip {
  static let reportOrder: [SessionBatchSkip] = [
    .alreadyClosed, .alreadyArchived, .notArchived, .alreadyInStatus, .stillRunning,
    .agentUnavailable, .busy, .needsSummary,
  ]
}
