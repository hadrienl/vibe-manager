import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// A store whose trace is read only once the test lets it go.
private actor HeldTraceStore: CoordinationStore {
  private var stored: [CoordinationTraceEntry]
  private var reading: CheckedContinuation<Void, Never>?
  private(set) var isReading = false

  init(stored: [CoordinationTraceEntry]) {
    self.stored = stored
  }

  func trace(of child: SessionID) async -> [CoordinationTraceEntry] {
    let snapshot = stored
    isReading = true
    await withCheckedContinuation { reading = $0 }
    return snapshot
  }

  func release() {
    reading?.resume()
    reading = nil
  }

  func append(_ entry: CoordinationTraceEntry, to child: SessionID) async {
    stored.append(entry)
  }

  func wakes() async -> [SessionID: CoordinationWake] { [:] }
  func setWake(_ wake: CoordinationWake?, for coordinator: SessionID) async {}
}

@MainActor
@Suite("A child's trace read from the store (#352)", .timeLimit(.minutes(1)))
struct CoordinationTraceLoadTests {
  private func entry(_ action: CoordinationTraceEntry.Action) -> CoordinationTraceEntry {
    CoordinationTraceEntry(date: Date(), coordinatorName: "V2", action: action)
  }

  @Test("What is recorded while the trace is read stays in it")
  func recordedWhileRead() async throws {
    let child = SessionID()
    let store = HeldTraceStore(stored: [entry(.created)])
    let model = CoordinationModel(store: store)
    let loading = Task { await model.loadTrace(of: child) }
    while !(await store.isReading) { try await Task.sleep(for: .milliseconds(5)) }
    model.record(entry(.messaged), for: child)
    await store.release()
    await loading.value
    #expect(model.traces[child]?.map(\.action) == [.created, .messaged])
  }
}
