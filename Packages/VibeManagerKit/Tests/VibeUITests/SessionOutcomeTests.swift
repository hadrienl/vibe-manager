import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
private final class OutcomeRecorder: RequestNotifying {
  private(set) var outcomes: [SessionOutcomeNotification] = []

  func post(_ notification: RequestNotification) {}
  func postOutcome(_ notification: SessionOutcomeNotification) { outcomes.append(notification) }
  func remove(_ ids: [AgentRequestID]) {}
  func setBadge(_ count: Int?) {}
  func isAuthorized() async -> Bool? { true }
}

@MainActor
@Suite("What is said when a session out of sight replies, fails or stops (#236)")
struct SessionOutcomeTests {
  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      taskStatus: .doing
    )
  }

  private func makeModel(_ sessions: [WorkSession]) async -> (AppModel, OutcomeRecorder) {
    let model = AppModel(
      repository: WorkspaceRepository(sessions: sessions),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    let recorder = OutcomeRecorder()
    model.requestNotifier = recorder
    return (model, recorder)
  }

  private let working = AgentActivityState(activity: .working, source: .structured)
  private let unread = AgentActivityState(
    activity: .idle, unreadSince: Date(timeIntervalSince1970: 50), source: .structured)

  @Test("An answer finished out of sight is said to VoiceOver, and notified in the background")
  func replied() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.activityDidChange(first.id, from: working, to: unread)
    #expect(Announcer.lastAnnouncement == "Replied · First")
    #expect(recorder.outcomes.map(\.sessionID) == [first.id])
    #expect(recorder.outcomes.first?.outcome == .replied)
    #expect(recorder.outcomes.first?.title.hasPrefix("First") == true)
  }

  @Test("In front, an answer finished in another session is said, not notified")
  func inFront() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)

    model.activityDidChange(first.id, from: working, to: unread)
    #expect(Announcer.lastAnnouncement == "Replied · First")
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("Once per answer: an answer still unread, or a state first seen at launch, says nothing")
  func once() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.activityDidChange(first.id, from: nil, to: unread)
    model.activityDidChange(first.id, from: unread, to: unread)
    model.activityDidChange(first.id, from: working, to: working)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("The session on screen says nothing: the user sees it")
  func onScreen() async {
    let first = session("First")
    let (model, recorder) = await makeModel([first])
    model.select(first.id)
    let before = Announcer.lastAnnouncement

    model.sessionDidEnd(first.id, .failed)
    #expect(Announcer.lastAnnouncement == before)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A process that fails or stops on its own is said, an error as one")
  func processes() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.processDidEnd(first.id, state: .exited(code: 1))
    #expect(Announcer.lastAnnouncement == "Failed · First")
    model.processDidEnd(first.id, state: .terminated(signal: 9))
    model.processDidEnd(first.id, state: .exited(code: 0))
    #expect(Announcer.lastAnnouncement == "Stopped · First")
    #expect(recorder.outcomes.map(\.outcome) == [.failed, .failed, .stopped])
  }

  @Test("Notifications turned off notify nothing; VoiceOver still hears it")
  func silenced() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()
    model.notifiesRequests = false

    model.activityDidChange(first.id, from: working, to: unread)
    #expect(Announcer.lastAnnouncement == "Replied · First")
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A click on the notification shows the session")
  func opens() async {
    let first = session("First")
    let second = session("Second")
    let (model, _) = await makeModel([first, second])
    model.select(second.id)

    model.openSession(first.id)
    #expect(model.selectedSessionID == first.id)
  }
}
