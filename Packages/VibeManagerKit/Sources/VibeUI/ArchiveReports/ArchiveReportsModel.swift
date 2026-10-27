import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The archive's reports, as the window shows them and the application forms them (#408).
@MainActor
@Observable
public final class ArchiveReportsModel {
  /// What the window shows on its right.
  public enum Selection: Hashable, Sendable {
    case batch(UUID)
    case period(ArchiveReportPeriod)
  }

  /// The agent's paragraph over a period, asked on demand and kept for this run.
  public enum PeriodSynthesis: Hashable, Sendable {
    case writing
    case ready(String)
    case failed
  }

  public private(set) var batches: [ArchiveBatch] = []
  public private(set) var loaded = false
  public var selection: Selection?
  /// Runs on trial are shown apart, when asked.
  public var showsTrials = false
  public private(set) var periodSyntheses: [ArchiveReportPeriod: PeriodSynthesis] = [:]
  /// Batches whose paragraph is being written.
  public private(set) var synthesizing: Set<UUID> = []

  @ObservationIgnored let book: ArchiveReportBook
  @ObservationIgnored let synthesizers: any ArchiveSynthesizerResolving
  @ObservationIgnored let diagnostics: Diagnostics
  @ObservationIgnored public var now: @MainActor () -> Date
  @ObservationIgnored public var calendar: @MainActor () -> Calendar
  /// The sessions as they stand, to mark the ones unarchived since. Given by the application's
  /// model.
  @ObservationIgnored var sessions: @MainActor () -> [WorkSession] = { [] }

  public init(
    store: any ArchiveReportStore = InMemoryArchiveReportStore(),
    synthesizers: any ArchiveSynthesizerResolving = NoArchiveSynthesizers(),
    diagnostics: Diagnostics = .disabled,
    now: @escaping @MainActor () -> Date = Date.init,
    calendar: @escaping @MainActor () -> Calendar = { .autoupdatingCurrent }
  ) {
    book = ArchiveReportBook(store: store)
    self.synthesizers = synthesizers
    self.diagnostics = diagnostics
    self.now = now
    self.calendar = calendar
  }

  // MARK: Reading

  /// Removes what is past the retention, then reads the batches.
  public func load() async {
    let removed = await book.prune(now: now(), calendar: calendar())
    if removed > 0 {
      diagnostics.record(.store, .info, "archive.reports.pruned", ["batches": .count(removed)])
    }
    batches = await book.batches()
    loaded = true
  }

  /// The batches the list shows, the latest day first, the latest batch first in its day.
  public var days: [(day: Date, batches: [ArchiveBatch])] {
    let calendar = calendar()
    let shown = batches.filter { showsTrials || !$0.isTrial }
    let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
    return grouped.keys.sorted(by: >).map { day in
      (day, grouped[day, default: []].sorted { $0.date > $1.date })
    }
  }

  public func batch(_ id: UUID) -> ArchiveBatch? {
    batches.first { $0.id == id }
  }

  /// The report of what is selected; `nil` when nothing is.
  public var report: ArchiveReport? {
    switch selection {
    case .batch(let id): batch(id).map { ArchiveReport(batch: $0, sessions: sessions()) }
    case .period(let period):
      ArchiveReport(
        batches: batches.filter { !$0.isTrial },
        interval: period.interval(now: now(), calendar: calendar()), sessions: sessions())
    case nil: nil
    }
  }

  // MARK: Forming

  /// A run of a rule that archived, or on trial would have, or a selection archived together:
  /// its batch, then its paragraph when the rule or the user asked for one.
  func recordRun(
    kind: ArchiveBatch.Kind, date: Date, sessions: [ArchivedSessionSnapshot],
    skipped: [SkippedSession] = [], summarizing: Bool
  ) async -> ArchiveBatch? {
    do {
      guard
        let batch = try await book.recordRun(
          kind: kind, date: date, sessions: sessions, skipped: skipped)
      else { return nil }
      diagnostics.record(
        .store, .info, "archive.reports.batch",
        [
          "sessions": .count(batch.sessions.count), "skipped": .count(batch.skipped.count),
          "trial": .flag(batch.isTrial),
        ])
      batches = await book.batches()
      if batch.offersSynthesis, summarizing { synthesize(batch.id) }
      return batch
    } catch {
      diagnostics.record(.store, .error, "archive.reports.writeFailed")
      return nil
    }
  }

  /// An archive of one session by hand, in the day's batch, which no agent summarizes.
  func recordByHand(_ snapshot: ArchivedSessionSnapshot) async {
    do {
      try await book.recordByHand(snapshot, calendar: calendar())
      batches = await book.batches()
    } catch {
      diagnostics.record(.store, .error, "archive.reports.writeFailed")
    }
  }

  // MARK: The agent's paragraph

  /// Writes the paragraph over a batch, in the background. A failure keeps the summary, and says
  /// so with Try Again.
  public func synthesize(_ id: UUID) {
    guard let batch = batch(id), batch.offersSynthesis, synthesizing.insert(id).inserted
    else { return }
    let request = ArchiveSynthesisRequest(
      report: ArchiveReport(batch: batch), language: Self.language)
    Task { [weak self] in
      guard let self else { return }
      let outcome = await self.write(request)
      self.synthesizing.remove(id)
      let synthesis: ArchiveSynthesis =
        switch outcome {
        case .success(let (text, provider)):
          .ready(text: text, providerID: provider, at: self.now())
        case .failure: .failed(at: self.now())
        }
      try? await self.book.setSynthesis(synthesis, of: id)
      self.batches = await self.book.batches()
    }
  }

  /// Writes the paragraph over a period, on demand: kept for this run only.
  public func summarize(_ period: ArchiveReportPeriod) {
    guard periodSyntheses[period] != .writing else { return }
    let report = ArchiveReport(
      batches: batches.filter { !$0.isTrial },
      interval: period.interval(now: now(), calendar: calendar()))
    guard !report.isEmpty else { return }
    periodSyntheses[period] = .writing
    let request = ArchiveSynthesisRequest(report: report, language: Self.language)
    Task { [weak self] in
      guard let self else { return }
      switch await self.write(request) {
      case .success(let (text, _)): self.periodSyntheses[period] = .ready(text)
      case .failure: self.periodSyntheses[period] = .failed
      }
    }
  }

  private func write(_ request: ArchiveSynthesisRequest) async -> Result<
    (String, String), ArchiveSynthesisError
  > {
    let started = ContinuousClock.now
    let result: Result<(String, String), ArchiveSynthesisError>
    if let (provider, synthesizer) = await synthesizers.synthesizer() {
      do {
        let data = try await synthesizer.synthesize(request)
        result = .success((try ArchiveSynthesisAnswer.decode(data), provider))
      } catch let error as ArchiveSynthesisError {
        result = .failure(error)
      } catch {
        result = .failure(.failed("unknown"))
      }
    } else {
      result = .failure(.noAgent)
    }
    diagnostics.record(
      .session, .info, "archive.reports.synthesis",
      [
        "outcome": .token(Self.token(of: result)), "truncated": .flag(request.isTruncated),
        "duration": .duration(ContinuousClock.now - started),
      ])
    return result
  }

  private static func token(of result: Result<(String, String), ArchiveSynthesisError>)
    -> DiagnosticToken
  {
    switch result {
    case .success: "ready"
    case .failure(.noAgent): "noAgent"
    case .failure(.timedOut): "timedOut"
    case .failure(.unreadable): "unreadable"
    case .failure(.failed): "failed"
    }
  }

  /// The language the paragraph is written in: the application's.
  static var language: String { Locale.current.language.minimalIdentifier }

  // MARK: Clearing

  /// Removes every batch. Says whether it could.
  @discardableResult
  public func clear() async -> Bool {
    do {
      try await book.removeAll()
    } catch {
      diagnostics.record(.store, .error, "archive.reports.clearFailed")
      return false
    }
    batches = await book.batches()
    periodSyntheses = [:]
    selection = nil
    return true
  }
}
