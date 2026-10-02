import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

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
@Suite("What is said when a session out of sight replies or its agent ends (#236)")
struct SessionOutcomeTests {
  private func session(_ name: String, in column: SessionTaskStatus = .doing) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      taskStatus: column
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

  /// What the sidebar shows for the session in this state: the one wording said.
  private func shown(
    _ session: WorkSession, _ status: TerminalPaneModel.Status,
    activity: AgentActivityState? = nil, launchFailed: Bool = false
  ) -> String {
    String(
      localized: SessionStatusPresentation.make(
        session: session, paneStatus: status, activity: activity, launchFailed: launchFailed
      ).label)
  }

  @Test("An answer finished out of sight is said as its row says it, and notified in the background")
  func replied() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.activityDidChange(first.id, from: working, to: unread)
    let state = shown(first, .running, activity: unread)
    #expect(Announcer.lastAnnouncement == "\(state) · First")
    #expect(recorder.outcomes.map(\.sessionID) == [first.id])
    #expect(recorder.outcomes.first?.body == state)
    #expect(recorder.outcomes.first?.title.hasPrefix("First") == true)
  }

  @Test("In front, an answer finished in another session is said, not notified")
  func inFront() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)

    model.activityDidChange(first.id, from: working, to: unread)
    #expect(Announcer.lastAnnouncement == "\(shown(first, .running, activity: unread)) · First")
    #expect(recorder.outcomes.isEmpty)
  }

  @Test(
    "Once per answer, and never for one already unread, restored, replayed, or ending on a request"
  )
  func once() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.activityDidChange(first.id, from: nil, to: unread)
    model.activityDidChange(first.id, from: unread, to: unread)
    model.activityDidChange(first.id, from: working, to: working)
    model.activityDidChange(first.id, from: working, to: unread, isReplayed: true)
    var asking = unread
    asking.activity = .awaitingUser(.question)
    asking.requests = [
      AgentRequest(
        id: AgentRequestID(sessionID: first.id, key: "plan"), receivedAt: Date(), kind: .question,
        content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: "ls")),
        reference: AgentToolReference(tool: "Bash", subject: "ls"), isShown: true)
    ]
    model.activityDidChange(first.id, from: working, to: asking)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("The session on screen says nothing: the user sees it")
  func onScreen() async {
    let first = session("First")
    let (model, recorder) = await makeModel([first])
    model.select(first.id)
    let before = Announcer.lastAnnouncement

    model.processDidEnd(first.id, state: .exited(code: 1))
    #expect(Announcer.lastAnnouncement == before)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A process that ends is said as its row says it: an error, a signal, a clean exit, a launch")
  func processes() async {
    let first = session("First")
    let second = session("Second")
    let (model, recorder) = await makeModel([first, second])
    model.select(second.id)
    model.applicationWillResignActive()

    model.processDidEnd(first.id, state: .exited(code: 1))
    #expect(Announcer.lastAnnouncement == "\(shown(first, .exited(code: 1))) · First")
    model.processDidEnd(first.id, state: .terminated(signal: 9))
    #expect(Announcer.lastAnnouncement == "\(shown(first, .terminated(signal: 9))) · First")
    model.processDidEnd(first.id, state: .exited(code: 0))
    #expect(Announcer.lastAnnouncement == "\(shown(first, .exited(code: 0))) · First")
    model.processDidEnd(first.id, state: .failed(.executableNotFound(path: "/nowhere/claude")))
    #expect(Announcer.lastAnnouncement == "\(shown(first, .failed(message: ""))) · First")
    model.processDidEnd(
      first.id, state: .failed(.executableNotFound(path: "/nowhere/claude")), launchFailed: true)
    let couldNotStart = shown(first, .failed(message: ""), launchFailed: true)
    #expect(couldNotStart != shown(first, .failed(message: "")))
    #expect(Announcer.lastAnnouncement == "\(couldNotStart) · First")
    #expect(
      recorder.outcomes.dropLast().map(\.body) == [
        shown(first, .exited(code: 1)), shown(first, .terminated(signal: 9)),
        shown(first, .exited(code: 0)), shown(first, .failed(message: "")),
      ])
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
    #expect(Announcer.lastAnnouncement?.hasSuffix(" · First") == true)
    #expect(recorder.outcomes.isEmpty)
  }

  @Test("A click on the notification shows the session, an archived one included")
  func opensArchived() async {
    let kept = session("Kept")
    var archived = session("Archived", in: .done)
    try? archived.archive(at: Date(timeIntervalSince1970: 500))
    let (model, _) = await makeModel([kept, archived])
    model.select(kept.id)

    model.openFromNotification(archived.id)
    await model.reload()
    #expect(model.selectedSessionID == archived.id)
  }
}
