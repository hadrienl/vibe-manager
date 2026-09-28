import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// A probe for which every process is alive and started at a fixed instant.
private struct SteadyProbe: ProcessLivenessProbe {
  func isAlive(processIdentifier: Int32) -> Bool { true }
  func startTime(of processIdentifier: Int32) -> Date? {
    Date(timeIntervalSince1970: 1_700_000_000)
  }
  func terminate(processGroup: Int32) -> Bool { false }
}

// What a session left running in the terminal host was still waiting for, carried from the
// instance that let it go to the one that takes it back (#141).
@Suite("The conversation a session left running still waits for")
struct AwaitedResumeIdentifierTests {
  private let identifier = "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04"

  @Test("Written beside the process kept running, and inherited by the next instance")
  func carriedAcrossAQuit() async {
    let store = EphemeralSessionRuntimeStateStore()
    let kept = SessionID()
    let other = SessionID()
    let quitting = SessionRuntimeRecorder(
      store: store, processIdentifier: 1_001, probe: SteadyProbe())
    await quitting.claim()
    await quitting.started(kept, processGroup: 7_001)
    await quitting.started(other, processGroup: 7_002)

    await quitting.awaiting(kept, resumeIdentifier: identifier)
    await quitting.markDetached(keeping: [kept, other], resuming: [], host: nil)

    let stored = await store.read()?.sessions
    #expect(stored?.first { $0.sessionID == kept }?.awaitedResumeIdentifier == identifier)
    #expect(stored?.first { $0.sessionID == kept }?.processGroup == 7_001)
    #expect(stored?.first { $0.sessionID == other }?.awaitedResumeIdentifier == nil)

    let next = SessionRuntimeRecorder(store: store, processIdentifier: 1_002, probe: SteadyProbe())
    await next.claim()

    #expect(await next.inheritedRecord(of: kept)?.awaitedResumeIdentifier == identifier)
    #expect(await next.inheritedRecord(of: other)?.awaitedResumeIdentifier == nil)
    // Taken over, the document holds nothing of the previous run until the session is adopted.
    #expect(await store.read()?.sessions.isEmpty == true)
  }

  @Test("Nothing is written for a session this instance does not run, and nothing twice")
  func awaitingOnlyTouchesARunningSession() async {
    let store = EphemeralSessionRuntimeStateStore()
    let recorder = SessionRuntimeRecorder(
      store: store, processIdentifier: 1_001, probe: SteadyProbe())
    await recorder.claim()

    await recorder.awaiting(SessionID(), resumeIdentifier: identifier)
    #expect(await store.read()?.sessions.isEmpty == true)

    let id = SessionID()
    await recorder.started(id, processGroup: 7_001, awaitedResumeIdentifier: identifier)
    await recorder.awaiting(id, resumeIdentifier: nil)
    #expect(await recorder.records().first?.awaitedResumeIdentifier == nil)
    #expect(await recorder.records().first?.processGroup == 7_001)
  }
}
