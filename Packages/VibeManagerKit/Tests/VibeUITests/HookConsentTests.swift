import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private actor NoSessions: SessionRepository {
  func sessions() -> [WorkSession] { [] }
  func session(id: SessionID) -> WorkSession? { nil }
  func save(_ session: WorkSession) {}
}

@MainActor
@Suite("Asking before a CLI's hooks are approved")
struct HookConsentTests {
  @Test("Launches waiting together get the one answer, and the sheet goes")
  func sharedAnswer() async {
    let model = AppModel(repository: NoSessions())
    let first = Task { await model.requestHookConsent(agentName: "Codex", commands: ["a"]) }
    let second = Task { await model.requestHookConsent(agentName: "Codex", commands: ["a"]) }
    while model.hookConsentWaiters.count < 2 { await Task.yield() }
    #expect(model.hookConsentRequest?.agentName == "Codex")
    model.answerHookConsent(.approved)
    #expect(await first.value == .approved)
    #expect(await second.value == .approved)
    #expect(model.hookConsentRequest == nil)
  }

  @Test("A launch called off while it waits gets no answer, and leaves the others waiting")
  func cancellation() async {
    let model = AppModel(repository: NoSessions())
    let cancelled = Task { await model.requestHookConsent(agentName: "Codex", commands: ["a"]) }
    let waiting = Task { await model.requestHookConsent(agentName: "Codex", commands: ["a"]) }
    while model.hookConsentWaiters.count < 2 { await Task.yield() }
    cancelled.cancel()
    #expect(await cancelled.value == .undecided)
    #expect(model.hookConsentRequest != nil)
    model.answerHookConsent(.declined)
    #expect(await waiting.value == .declined)
  }
}
