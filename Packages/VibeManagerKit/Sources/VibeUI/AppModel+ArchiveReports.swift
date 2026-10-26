import Foundation
import VibeApplication
import VibeDomain

/// Forming the archive's batches (#408): each session photographed as it stands, right before it
/// is archived, with its journal and its usage.
extension AppModel {
  /// Reads the batches, and tells the reports what they need of the sessions.
  func startArchiveReports() async {
    guard let archiveReports else { return }
    archiveReports.sessions = { [weak self] in self?.sessions ?? [] }
    archiveReports.journalSummarizes = { [weak self] in self?.journal?.summariesEnabled ?? true }
    await archiveReports.load()
  }

  /// A session as a report keeps it.
  func archiveSnapshot(of session: WorkSession, at date: Date) async -> ArchivedSessionSnapshot {
    let journal = await journal?.reader(session.id)
    let usage = usage?.sessionUsage[session.id]?.total
    return ArchivedSessionSnapshot(
      session: session, archivedAt: date, project: groupName(of: session), journal: journal,
      runningTime: usage.map(\.runningTime).flatMap { $0 > 0 ? $0 : nil }, tokens: usage?.tokens)
  }

  /// An archive by hand, added to the day's batch.
  func recordArchiveByHand(_ session: WorkSession) async {
    guard let archiveReports else { return }
    await archiveReports.recordByHand(await archiveSnapshot(of: session, at: Date()))
  }

  /// Opens the reports' window on a batch.
  public func showArchiveReport(_ id: UUID) {
    archiveReports?.selection = .batch(id)
    showArchiveReportsWindow?()
  }

  /// Opens the reports' window, on yesterday when nothing is chosen yet.
  public func showArchiveReports() {
    if archiveReports?.selection == nil { archiveReports?.selection = .period(.yesterday) }
    showArchiveReportsWindow?()
  }
}
