import Foundation
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The usage of a long and costly conversation, read from nowhere and the same at every reading:
/// what the status bar draws when its Usage button is at its widest (#575).
enum StatusBarUsage {
  static let model = "claude-sonnet-4-5-20250929"

  @MainActor
  static func usage(of session: SessionID) -> UsageModel {
    let snapshot = TokenUsageSnapshot(files: [
      "transcript": TokenUsageFile(
        sessionID: session, providerID: "claude-code", currentModel: model,
        tallies: [
          .init(
            model: model, day: LocalDay(Date(), calendar: .current),
            tokens: TokenCounts(
              input: 120_000, cacheRead: 9_000_000, cacheWrite: 800_000, output: 300_000),
            responses: 400)
        ])
    ])
    var context = ContextWindowFile()
    context.usage = ContextWindowUsage(
      usedTokens: 182_000, windowSize: 200_000, measuredAt: Date(), lastCompaction: nil)
    let ledger = NoLedger()
    let tracking = NoTracking()
    // Dear enough for a cost in thousands: the widest the label draws.
    let price = ModelPrice(input: 0.01, cacheRead: 0.0001, cacheWrite: 0.001, output: 0.001)
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking), ledger: ledger,
      tracking: tracking, tokenStore: FixedTokens(snapshot: snapshot),
      reader: FixedTokens(snapshot: snapshot), contextReader: FixedContext(file: context),
      prices: ModelPriceUpdater(
        fetcher: NoFetch(), store: NoPrices(),
        bundled: ModelPriceList(fetchedAt: Date(), prices: [model: price])))
    return UsageModel(service: service, refreshInterval: .seconds(3_600))
  }

  private actor NoLedger: UsageLedger {
    func append(_ event: UsageLedgerEvent) async throws {
      // Nothing is kept: the figures are the transcript's.
    }
    func events() async throws -> [UsageLedgerEvent] { [] }
    func writeHeartbeat(_ heartbeat: UsageHeartbeat?) async throws {
      // Nothing is kept.
    }
    func heartbeat() async -> UsageHeartbeat? { nil }
    func clear() async throws {
      // Nothing was kept.
    }
  }

  private struct NoTracking: UsageTrackingStore {
    /// On since a day ago.
    func intervals() async -> [UsageTrackingInterval] {
      [UsageTrackingInterval(from: Date().addingTimeInterval(-86_400))]
    }
    func save(_ intervals: [UsageTrackingInterval]) async throws {
      // Tracking stays on.
    }
  }

  private struct FixedTokens: TokenUsageStore, TokenUsageReading {
    let snapshot: TokenUsageSnapshot
    func load() async -> TokenUsageSnapshot { snapshot }
    func save(_ snapshot: TokenUsageSnapshot) async throws {
      // The same figures at every reading.
    }
    func clear() async throws {
      // The same figures at every reading.
    }
    func refresh(
      _ sessions: [WorkSession], from snapshot: TokenUsageSnapshot,
      isTracked: @escaping @Sendable (Date) -> Bool
    ) async -> TokenUsageSnapshot {
      self.snapshot
    }
  }

  private struct FixedContext: ContextWindowReading {
    let file: ContextWindowFile
    func readContext(
      of conversation: SessionAgentConfiguration, session: WorkSession,
      from file: ContextWindowFile?
    ) async -> ContextWindowFile? {
      self.file
    }
  }

  private struct NoFetch: ModelPriceFetching {
    func fetchPriceList() async throws -> Data { throw CancellationError() }
  }

  private struct NoPrices: ModelPriceStore {
    func load() async -> ModelPriceList? { nil }
    func save(_ list: ModelPriceList) async throws {
      // The list given is the one kept.
    }
  }
}
