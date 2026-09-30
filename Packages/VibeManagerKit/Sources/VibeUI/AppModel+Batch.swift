import Foundation
import VibeApplication
import VibeDomain

/// The one question a command on several sessions asks (#77).
public struct SessionBatchConfirmation: Equatable, Identifiable {
  public let plan: SessionBatchPlan
  public let title: String
  public let message: String
  public let confirmTitle: String
  /// A second way to answer yes, for a move In Progress that would restart many agents at once
  /// (#192): the sessions are moved and nothing is restarted. Offered first, as the default.
  public let withoutRestartTitle: String?

  public var id: SessionBatchAction { plan.action }

  /// Closing asks the question of #51, and offers its "Don't ask again".
  public var isClose: Bool { plan.action == .close }
}

/// What a command on several sessions could not do, in one place (#77). Like the restoration's,
/// a list and never one dialog per session.
public struct SessionBatchReport: Equatable {
  public struct Line: Equatable, Identifiable {
    public let id: SessionID
    public let text: String
    public let suggestion: String?
  }

  public let message: String
  public let lines: [Line]
}

/// Commands on several sessions (#77).
///
/// A batch invents no rule: a session is eligible exactly when the command would be offered for
/// it alone, and each one goes through the same use case it would go through on its own. What
/// changes is that the question is asked once, the list reloaded once, and every outcome told
/// in one report — a failure on one session never stops the others.
extension AppModel {
  /// Past this many agents to restart, a move In Progress warns of the wait and defaults to
  /// moving without restarting (#192). Restarts run one after the other, a few seconds each.
  static let batchRestartWarningThreshold = 5

  // MARK: - Plan

  public func batchPlan(_ action: SessionBatchAction, for ids: [SessionID]) -> SessionBatchPlan {
    SessionBatchPlan.make(action, ids: ids) { id in
      // A session gone from the store since the menu was drawn has nothing left to do.
      guard let session = sessions.first(where: { $0.id == id }) else { return .busy }
      return skip(action, for: session)
    }
  }

  private func skip(_ action: SessionBatchAction, for session: WorkSession) -> SessionBatchSkip? {
    switch action {
    case .close:
      if canClose(session) { return nil }
      if closingSessionIDs.contains(session.id) { return .busy }
      return session.status == .archived ? .alreadyArchived : .alreadyClosed
    case .archive:
      return canArchive(session) ? nil : .alreadyArchived
    case .unarchive:
      return canRestore(session) ? nil : .notArchived
    case .restart:
      if canRestart(session) { return nil }
      if session.status == .archived { return .alreadyArchived }
      if session.status == .active || launcher?.isRunning(session.id) == true {
        return .stillRunning
      }
      if restartingSessionIDs.contains(session.id) || pendingRestart?.sessionID == session.id
        || pendingSwitch?.sessionID == session.id
      {
        return .busy
      }
      return .agentUnavailable
    case .move(let status):
      if session.taskStatus == .archived { return .alreadyArchived }
      return session.taskStatus == status ? .alreadyInStatus : nil
    }
  }

  /// What a menu calls the command: how many sessions it will actually act on.
  public func batchTitle(for plan: SessionBatchPlan) -> String {
    let count = plan.eligible.count
    switch plan.action {
    case .close:
      return String(
        localized: "Close \(count) Sessions", bundle: .module,
        comment: "A command on several selected sessions.")
    case .archive:
      return String(
        localized: "Archive \(count) Sessions…", bundle: .module,
        comment: "A command on several selected sessions.")
    case .unarchive:
      return String(
        localized: "Unarchive \(count) Sessions", bundle: .module,
        comment: "A command on several selected sessions.")
    case .restart:
      return String(
        localized: "Restart \(count) Sessions…", bundle: .module,
        comment: "A command on several selected sessions.")
    case .move(let status):
      return String(
        localized: "Move \(count) Sessions to \(String(localized: status.label))…",
        bundle: .module,
        comment: "A command on several selected sessions: how many, a task status.")
    }
  }

  /// ⌥⌘→ and ⌥⌘← on a selection of several: the column next to the one on screen.
  public func batchMovePlan(forward: Bool) -> SessionBatchPlan? {
    guard let session = selectedSession else { return nil }
    let candidates = forward ? nextTaskStatuses(of: session) : previousTaskStatuses(of: session)
    guard let target = candidates.first, target != .archived else { return nil }
    let plan = batchPlan(.move(to: target), for: commandTargets)
    return plan.isEmpty ? nil : plan
  }

  // MARK: - Asking

  /// Runs the command, or asks first when it would do so for one session — and for a restart
  /// or a move of several, whose cost is several agents at once.
  public func requestBatch(_ plan: SessionBatchPlan) async {
    guard !plan.isEmpty else { return }
    batchReport = nil
    if let confirmation = confirmation(for: plan) {
      pendingBatch = confirmation
      return
    }
    await performBatch(plan, skipsAnnounced: false)
  }

  /// Takes the confirmation rather than reading `pendingBatch`, for the reason `archive(_:)`
  /// gives: SwiftUI dismisses the dialog, and clears it, before the button runs.
  ///
  /// `restarting: false` is the answer "Move Without Restarting" gives (#192).
  public func confirmBatch(
    _ confirmation: SessionBatchConfirmation, askAgain: Bool = true, restarting: Bool = true
  ) async {
    pendingBatch = nil
    if confirmation.isClose, !askAgain {
      confirmsStoppingRunningAgent = false
    }
    await performBatch(confirmation.plan, skipsAnnounced: true, restarting: restarting)
  }

  public func cancelBatch() {
    pendingBatch = nil
  }

  public func dismissBatchReport() {
    batchReport = nil
  }

  func confirmation(for plan: SessionBatchPlan) -> SessionBatchConfirmation? {
    let count = plan.eligible.count
    let eligible = plan.eligible.compactMap { id in sessions.first { $0.id == id } }
    var sentences: [String] = []
    let title: String
    var confirmTitle: String
    var withoutRestartTitle: String?
    switch plan.action {
    case .archive:
      title = String(localized: "Archive \(count) Sessions?", bundle: .module)
      confirmTitle = String(localized: "Archive", bundle: .module)
      let running = eligible.filter { launcher?.isRunning($0.id) == true }.count
      if running > 0 {
        sentences.append(
          String(localized: "The agents of \(running) sessions will be stopped.", bundle: .module))
      }
      sentences.append(
        String(
          localized: """
            Nothing is deleted: notes, repositories and Git metadata are kept, and the sessions \
            stay readable under Archived. They can no longer be reopened until they are unarchived.
            """,
          bundle: .module,
          comment: "Archived is the line at the foot of the sidebar that lists archived sessions."))
    case .close:
      guard eligible.contains(where: interruptsWork) else { return nil }
      title = String(localized: "Close \(count) Sessions?", bundle: .module)
      confirmTitle = batchTitle(for: plan)
      let running = eligible.filter { launcher?.isRunning($0.id) == true }.count
      if running > 0 {
        sentences.append(
          String(
            localized:
              "\(running) running agents will be stopped. The sessions can be restarted later.",
            bundle: .module))
      }
      // Only side terminals at work (#115): what they run is what closing stops.
      if eligible.contains(where: { !runningDrawerCommands(of: $0.id).isEmpty }) {
        sentences.append(
          String(
            localized: "What runs in their side terminals will be stopped.", bundle: .module))
      }
    case .restart:
      guard count > 1 else { return nil }
      title = String(localized: "Restart \(count) Sessions?", bundle: .module)
      confirmTitle = String(
        localized: "Restart Sessions", bundle: .module, comment: "Restarts several sessions.")
      sentences.append(
        String(
          localized: """
            Each agent resumes its conversation where it can. A session whose summary has to be \
            read first is left for you to restart on its own.
            """,
          bundle: .module))
    case .move(let status):
      guard count > 1 else { return nil }
      let label = String(localized: status.label)
      title = String(
        localized: "Move \(count) Sessions to \(label)?", bundle: .module,
        comment: "How many sessions, then a task status.")
      confirmTitle = String(
        localized: "Move Sessions", bundle: .module, comment: "Moves several sessions.")
      let starting = eligible.filter { Self.restartsWhenMoved($0, to: status) && canRestart($0) }
        .count
      if starting > 0 {
        sentences.append(
          String(
            localized: "\(starting) sessions will start their agent again.", bundle: .module,
            comment: "Moving several sessions In Progress restarts the closed ones."))
      }
      if starting > Self.batchRestartWarningThreshold {
        sentences.append(
          String(
            localized: """
              Their agents start one after the other, which can take several minutes and slow \
              this Mac down.
              """,
            bundle: .module))
        confirmTitle = String(
          localized: "Move and Restart", bundle: .module,
          comment: "Moves several sessions In Progress and restarts their agents.")
        withoutRestartTitle = String(
          localized: "Move Without Restarting", bundle: .module,
          comment: "Moves several sessions In Progress and starts no agent.")
      }
    case .unarchive:
      return nil
    }
    sentences += skipSentences(plan.skippedCounts, action: plan.action)
    return SessionBatchConfirmation(
      plan: plan, title: title, message: sentences.joined(separator: " "),
      confirmTitle: confirmTitle, withoutRestartTitle: withoutRestartTitle)
  }

  // MARK: - Running

  func performBatch(
    _ plan: SessionBatchPlan, skipsAnnounced: Bool, restarting: Bool = true
  ) async {
    // Asked again: a session may have been closed, restarted or archived since the question.
    let current = batchPlan(plan.action, for: plan.eligible)
    var results = current.skipped.mapValues { SessionBatchItemResult.skipped($0) }
    let listedBefore = displayedSessions.map(\.id)
    let shown = selectedSessionID
    diagnostics.record(
      .session, .info, "session.batch",
      ["count": .count(current.eligible.count)])

    switch plan.action {
    case .close:
      // Side by side: each stop waits out its own grace period, and ten agents stopped one after
      // the other would hold the last one for half a minute.
      results.merge(await concurrently(current.eligible) { await $0.closeInBatch($1) }) { $1 }
    case .archive:
      results.merge(await concurrently(current.eligible) { await $0.archiveInBatch($1) }) { $1 }
    case .unarchive:
      for id in current.eligible { results[id] = await restoreInBatch(id) }
    case .restart:
      // One after the other, as the restoration does: several agents starting at once on a cold
      // disk is an application that stops answering.
      for id in current.eligible { results[id] = await restartInBatch(id) }
    case .move(let status):
      for id in current.eligible {
        results[id] = await moveInBatch(id, to: status, restarting: restarting)
      }
    }

    let left = Set(results.filter { $0.value.isDone }.map(\.key))
    // A move In Progress follows its sessions to their column rather than staying (#192).
    let isMoveInProgress = plan.action == .move(to: .doing)
    let leavesColumn: Bool
    switch plan.action {
    case .archive: leavesColumn = true
    case .move: leavesColumn = !isMoveInProgress
    default: leavesColumn = false
    }
    // The session on screen that left the column hands the selection to the row that takes its
    // place, as it does on its own.
    if leavesColumn, let shown, left.contains(shown),
      let index = listedBefore.firstIndex(of: shown)
    {
      let neighbour =
        listedBefore[index...].first { !left.contains($0) }
        ?? listedBefore[..<index].last { !left.contains($0) }
      if let neighbour { preferredSelection = neighbour }
    }
    await reload()
    if plan.action == .restart || isMoveInProgress {
      followBatch(
        shown: shown, moved: listedBefore.filter(left.contains),
        handsOverSelection: isMoveInProgress)
    }
    reconcileSelection()

    if case .move(let status) = plan.action, !left.isEmpty {
      Announcer.announce(
        String(
          localized: "\(left.count) sessions moved to \(String(localized: status.label)).",
          bundle: .module, comment: "How many sessions, then a task status."))
    }
    let announced =
      skipsAnnounced ? [:] : plan.skipped.mapValues { SessionBatchItemResult.skipped($0) }
    batchReport = report(
      plan.action, results: results.merging(announced) { current, _ in current },
      order: plan.eligible
        + plan.skipped.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
  }

  /// A restart puts its sessions In Progress, and so does a move there. The column follows the
  /// session on screen, as it does for one session on its own, rather than falling to the first
  /// row of the column it left. When the session on screen is not one of those moved, a move
  /// hands the selection to the first of them, in the order of the sidebar (#192).
  private func followBatch(shown: SessionID?, moved: [SessionID], handsOverSelection: Bool) {
    let target: SessionID?
    if let shown, moved.contains(shown) {
      target = shown
    } else {
      target = handsOverSelection ? moved.first : nil
    }
    guard let target, let session = sessions.first(where: { $0.id == target }),
      session.taskStatus != .archived
    else { return }
    if session.taskStatus != filter.column { update { $0.column = session.taskStatus } }
    if selectedSessionID != target { select(target) }
  }

  private func concurrently(
    _ ids: [SessionID],
    _ body: @escaping @MainActor @Sendable (AppModel, SessionID) async -> SessionBatchItemResult
  ) async -> [SessionID: SessionBatchItemResult] {
    // Tasks of the main actor, started together: each one runs while the others wait on a stop.
    let tasks = ids.map { id in (id, Task { await body(self, id) }) }
    var results: [SessionID: SessionBatchItemResult] = [:]
    for (id, task) in tasks { results[id] = await task.value }
    return results
  }

  // MARK: - Report

  /// Silence when everything went through: a batch that worked has nothing to say.
  func report(
    _ action: SessionBatchAction, results: [SessionID: SessionBatchItemResult], order: [SessionID]
  ) -> SessionBatchReport? {
    var notDone: [SessionBatchReport.Line] = []
    var warnings: [SessionBatchReport.Line] = []
    var notStarted: [SessionBatchReport.Line] = []
    var skipped: [SessionBatchSkip: Int] = [:]
    for id in order {
      guard let result = results[id] else { continue }
      let name =
        sessions.first { $0.id == id }?.name ?? String(localized: "This session", bundle: .module)
      switch result {
      case .done:
        continue
      case .doneWithWarning(let message, let suggestion):
        warnings.append(.init(id: id, text: message, suggestion: suggestion))
      case .movedWithoutStart(let message, let suggestion):
        notStarted.append(.init(id: id, text: Self.line(name, message), suggestion: suggestion))
      case .failed(let message, let suggestion):
        notDone.append(.init(id: id, text: Self.line(name, message), suggestion: suggestion))
      case .skipped(.needsSummary):
        notDone.append(
          .init(
            id: id,
            text: Self.line(
              name,
              String(
                localized: "Its summary has to be read first: restart it on its own.",
                bundle: .module)),
            suggestion: nil))
      case .skipped(let reason):
        skipped[reason, default: 0] += 1
      }
    }
    var sentences: [String] = []
    if !notDone.isEmpty { sentences.append(notDoneSentence(action, count: notDone.count)) }
    sentences += skipSentences(
      SessionBatchSkip.reportOrderForUI.compactMap { reason in
        skipped[reason].map { (reason, $0) }
      }, action: action)
    if !notStarted.isEmpty {
      sentences.append(
        String(
          localized: "\(notStarted.count) sessions were moved, but their agent did not start.",
          bundle: .module))
    }
    if !warnings.isEmpty {
      sentences.append(
        String(
          localized:
            "\(warnings.count) processes did not answer the stop and may still be running.",
          bundle: .module))
    }
    guard !sentences.isEmpty else { return nil }
    return SessionBatchReport(
      message: sentences.joined(separator: " "), lines: notDone + notStarted + warnings)
  }

  private static func line(_ name: String, _ sentence: String) -> String {
    String(
      localized: "\(name): \(sentence)", bundle: .module,
      comment: "A session's name, then what a command on several sessions could not do with it.")
  }

  private func notDoneSentence(_ action: SessionBatchAction, count: Int) -> String {
    switch action {
    case .close:
      return String(localized: "\(count) sessions were not closed.", bundle: .module)
    case .archive:
      return String(localized: "\(count) sessions were not archived.", bundle: .module)
    case .unarchive:
      return String(localized: "\(count) sessions were not unarchived.", bundle: .module)
    case .restart:
      return String(localized: "\(count) sessions were not restarted.", bundle: .module)
    case .move(let status):
      return String(
        localized: "\(count) sessions were not moved to \(String(localized: status.label)).",
        bundle: .module, comment: "How many sessions, then a task status.")
    }
  }

  private func skipSentences(
    _ counts: [(reason: SessionBatchSkip, count: Int)], action: SessionBatchAction
  ) -> [String] {
    counts.map { reason, count in
      switch reason {
      case .alreadyClosed:
        return String(
          localized: "\(count) are already closed.", bundle: .module,
          comment: "Sessions of the selection a command leaves out.")
      case .alreadyArchived:
        return String(
          localized: "\(count) are already archived.", bundle: .module,
          comment: "Sessions of the selection a command leaves out.")
      case .notArchived:
        return String(
          localized: "\(count) are not archived.", bundle: .module,
          comment: "Sessions of the selection a command leaves out.")
      case .alreadyInStatus:
        guard case .move(let status) = action else {
          return String(
            localized: "\(count) are left as they are.", bundle: .module,
            comment: "Sessions of the selection a command leaves out.")
        }
        return String(
          localized: "\(count) are already in \(String(localized: status.label)).",
          bundle: .module,
          comment: "Sessions of the selection a command leaves out, then a task status.")
      case .stillRunning:
        return String(
          localized: "\(count) are still running and are left as they are.",
          bundle: .module, comment: "Sessions of the selection a command leaves out.")
      case .agentUnavailable:
        return String(
          localized: "\(count) have no agent that can run.", bundle: .module,
          comment: "Sessions of the selection a command leaves out.")
      case .busy:
        return String(
          localized: "\(count) are already being closed or restarted.",
          bundle: .module, comment: "Sessions of the selection a command leaves out.")
      case .needsSummary:
        return String(
          localized: "\(count) need their summary read first: restart them one at a time.",
          bundle: .module, comment: "Sessions of the selection a command leaves out.")
      }
    }
  }
}

extension SessionBatchItemResult {
  var isDone: Bool {
    switch self {
    case .done, .doneWithWarning, .movedWithoutStart: return true
    case .skipped, .failed: return false
    }
  }
}

extension SessionBatchSkip {
  static let reportOrderForUI: [SessionBatchSkip] = [
    .alreadyClosed, .alreadyArchived, .notArchived, .alreadyInStatus, .stillRunning,
    .agentUnavailable, .busy,
  ]
}
