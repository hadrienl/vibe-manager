import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("The context window of a session")
struct ContextWindowServiceTests {
  private actor CountingReader: ContextWindowReading {
    var calls = 0

    func readContext(
      of conversation: SessionAgentConfiguration, session: WorkSession,
      from file: ContextWindowFile?
    ) async -> ContextWindowFile? {
      calls += 1
      var next = file ?? ContextWindowFile()
      next.usage = ContextWindowUsage(usedTokens: 1_000, measuredAt: Date())
      return next
    }
  }

  private func service(tracking: Bool, reader: CountingReader) -> UsageService {
    let store = InMemoryUsageTrackingStore(
      intervals: tracking
        ? [UsageTrackingInterval(from: .distantPast)]
        : [UsageTrackingInterval(from: .distantPast, to: Date().addingTimeInterval(-60))])
    let ledger = InMemoryUsageLedger()
    return UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: store), ledger: ledger, tracking: store,
      tokenStore: InMemoryTokenUsageStore(), reader: nil, contextReader: reader)
  }

  private let session = WorkSession(
    name: "S", agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: "id"))

  @Test("Tracking off, no transcript is read")
  func trackingOff() async {
    let reader = CountingReader()
    #expect(await service(tracking: false, reader: reader).contextWindow(for: session) == nil)
    #expect(await reader.calls == 0)
  }

  @Test("Tracking on, the current conversation is read, and nothing is saved")
  func trackingOn() async {
    let reader = CountingReader()
    let usage = await service(tracking: true, reader: reader).contextWindow(for: session)
    #expect(usage?.usedTokens == 1_000)
    #expect(await reader.calls == 1)
  }

  @Test("A session that never had a conversation has no context")
  func noConversation() async {
    let reader = CountingReader()
    let fresh = WorkSession(name: "S", agent: SessionAgentConfiguration(providerID: "codex"))
    #expect(await service(tracking: true, reader: reader).contextWindow(for: fresh) == nil)
  }
}
