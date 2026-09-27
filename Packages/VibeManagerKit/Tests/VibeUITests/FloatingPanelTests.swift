import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

@MainActor
private final class CountingNotifier: RequestNotifying {
  private(set) var posted: [RequestNotification] = []
  private(set) var badge: Int??

  func post(_ notification: RequestNotification) { posted.append(notification) }
  func remove(_ ids: [AgentRequestID]) {}
  func setBadge(_ count: Int?) { badge = .some(count) }
  func isAuthorized() async -> Bool? { true }
}

@MainActor
@Suite("The floating panel of requests")
struct FloatingPanelTests {
  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name, initialPrompt: "Do \(name)", agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active, createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1), repositories: [], taskStatus: .doing)
  }

  private func makeModel(
    _ sessions: [WorkSession], preferences: InMemoryFloatingPanelPreferences = .init()
  ) async -> (AppModel, FloatingRequestPanelModel) {
    let model = AppModel(
      repository: WorkspaceRepository(sessions: sessions),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    let panel = FloatingRequestPanelModel(preferences: preferences)
    model.floatingPanel = panel
    return (model, panel)
  }

  @discardableResult
  private func ask(
    _ command: String, in session: WorkSession, at seconds: TimeInterval, model: AppModel
  ) -> AgentRequestID {
    let id = AgentRequestID(sessionID: session.id, key: command)
    var state = model.activities[session.id] ?? AgentActivityState(source: .structured)
    state.activity = .awaitingUser(.approval)
    state.requests.append(
      AgentRequest(
        id: id, receivedAt: Date(timeIntervalSince1970: seconds), kind: .approval,
        content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
        reference: AgentToolReference(tool: "Bash", subject: command), isShown: true))
    model.activities[session.id] = state
    model.requestAnswering[id] = .fromPalette([.allowOnce, .deny])
    model.requestsDidChange()
    return id
  }

  @Test("Off by default: never shown, and the notifications of #40 are unchanged")
  func offByDefault() async {
    let first = session("First")
    let (model, panel) = await makeModel([first])
    let notifier = CountingNotifier()
    model.requestNotifier = notifier
    model.select(nil)
    model.applicationWillResignActive()
    ask("ls", in: first, at: 10, model: model)

    #expect(!panel.isEnabled)
    #expect(!panel.isShown)
    #expect(notifier.posted.count == 1)
  }

  @Test("On: hidden while Vibe Manager is in front with its window, shown when it is not")
  func noDuplicate() async {
    let first = session("First")
    let (model, panel) = await makeModel([first], preferences: .init(showsFloatingPanel: true))
    model.select(nil)
    ask("ls", in: first, at: 10, model: model)

    #expect(!panel.isShown)
    #expect(model.pendingRequests.count == 1)

    model.applicationWillResignActive()
    #expect(panel.isShown)

    model.applicationDidBecomeActive()
    #expect(!panel.isShown)

    // In front, but its window closed or minimised: the sidebar is not seen.
    model.mainWindowVisibilityChanged(false)
    #expect(panel.isShown)
  }

  @Test("In the background, the selected session's requests have their bubble too")
  func selectedSession() async {
    let first = session("First")
    let (model, panel) = await makeModel([first], preferences: .init(showsFloatingPanel: true))
    model.select(first.id)
    ask("ls", in: first, at: 10, model: model)
    #expect(model.pendingRequests.isEmpty)

    model.applicationWillResignActive()
    #expect(panel.requests.map(\.session.id) == [first.id])
  }

  @Test("With nothing pending: hidden, or the avatar alone when asked")
  func idle() async {
    let (model, panel) = await makeModel([session("First")])
    panel.isEnabled = true
    model.applicationWillResignActive()
    #expect(!panel.isShown)
    panel.idle = .avatarOnly
    #expect(panel.isShown)
  }

  @Test("The word about the last answer keeps the bubble up, but never a folded avatar")
  func outcomeWhileFolded() async {
    let (model, panel) = await makeModel([session("First")])
    panel.isEnabled = true
    model.applicationWillResignActive()
    model.requestOutcome = RequestOutcome(
      id: UUID(), sessionName: "First", answer: .allowOnce, outcome: .sent)
    #expect(panel.isShown)

    // Folded, the line that clears it is not drawn: it would stay above everything.
    panel.toggleCollapsed()
    #expect(!panel.isShown)
  }

  @Test("A tall bubble opening past an edge is moved back on screen, its top kept first")
  func fitsOnScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let fit = FloatingRequestPanelController.fit
    // Opened upward from just below the middle: its top was 100 points past the edge.
    #expect(
      fit(CGRect(x: 600, y: 350, width: 300, height: 550), screen)
        == CGRect(x: 600, y: 250, width: 300, height: 550))
    // Opened downward from just above the middle.
    #expect(
      fit(CGRect(x: 600, y: -100, width: 300, height: 550), screen)
        == CGRect(x: 600, y: 0, width: 300, height: 550))
    #expect(
      fit(CGRect(x: 600, y: 100, width: 300, height: 400), screen)
        == CGRect(x: 600, y: 100, width: 300, height: 400))
    // Taller than the screen: the start of the card stays in view.
    #expect(
      fit(CGRect(x: 600, y: -300, width: 300, height: 900), screen)
        == CGRect(x: 600, y: -100, width: 300, height: 900))
  }

  @Test("While it is on, no notification repeats a request the bubble shows; the badge stays")
  func noNotification() async {
    let first = session("First")
    let (model, panel) = await makeModel([first], preferences: .init(showsFloatingPanel: true))
    let notifier = CountingNotifier()
    model.requestNotifier = notifier
    model.select(nil)
    model.applicationWillResignActive()
    ask("ls", in: first, at: 10, model: model)

    #expect(panel.isShown)
    #expect(notifier.posted.isEmpty)
    #expect(notifier.badge == .some(1))
  }

  @Test("The bubble shows the oldest; the counter moves on and back, stopping at both ends")
  func counter() async {
    let first = session("First")
    let second = session("Second")
    let (model, panel) = await makeModel(
      [first, second], preferences: .init(showsFloatingPanel: true))
    model.applicationWillResignActive()
    let old = ask("ls", in: second, at: 10, model: model)
    let new = ask("make", in: first, at: 20, model: model)

    #expect(panel.current?.id == old)
    #expect(panel.position?.index == 1 && panel.position?.count == 2)
    panel.show(offset: 1)
    #expect(panel.current?.id == new)
    panel.show(offset: 1)
    #expect(panel.current?.id == new)
    panel.show(offset: -5)
    #expect(panel.current?.id == old)
  }

  @Test("A request settled elsewhere: the bubble goes to the oldest left")
  func settledElsewhere() async {
    let first = session("First")
    let second = session("Second")
    let (model, panel) = await makeModel(
      [first, second], preferences: .init(showsFloatingPanel: true))
    model.applicationWillResignActive()
    let old = ask("ls", in: second, at: 10, model: model)
    let new = ask("make", in: first, at: 20, model: model)
    panel.show(offset: 1)
    #expect(panel.current?.id == new)

    model.activities[first.id]?.requests.removeAll()
    model.requestsDidChange()
    #expect(panel.current?.id == old)
  }

  @Test("Folded, the setting and the positions are kept")
  func preferences() async {
    let preferences = InMemoryFloatingPanelPreferences()
    let (_, panel) = await makeModel([], preferences: preferences)
    panel.isEnabled = true
    panel.idle = .avatarOnly
    panel.toggleCollapsed()
    panel.setAnchor(FloatingPanelAnchor(x: 0.2, y: 1.4), forDisplay: "screen")

    #expect(preferences.showsFloatingPanel)
    #expect(preferences.idle == .avatarOnly)
    #expect(preferences.isCollapsed)
    #expect(preferences.anchors["screen"] == FloatingPanelAnchor(x: 0.2, y: 1))

    panel.resetPositions()
    #expect(preferences.anchors.isEmpty)
  }

  @Test("⌃⌥⌘P unfolds the bubble and asks it to take the keyboard")
  func focus() async {
    let (_, panel) = await makeModel([], preferences: .init(isCollapsed: true))
    panel.focus()
    #expect(!panel.isCollapsed)
    #expect(panel.focusRequest == 1)
  }

  @Test("Opening a session from the bubble brings Vibe Manager forward")
  func openSession() async {
    let first = session("First")
    let (model, _) = await makeModel([first], preferences: .init(showsFloatingPanel: true))
    var activated = 0
    model.activateApplication = { activated += 1 }
    model.applicationWillResignActive()
    let id = ask("ls", in: first, at: 10, model: model)

    model.openSession(for: id)
    #expect(activated == 1)
    #expect(model.selectedSessionID == first.id)
  }

  @Test("What the avatar reads out: the session, and what it asks")
  func speech() async throws {
    let first = session("Refacto")
    let (model, panel) = await makeModel([first], preferences: .init(showsFloatingPanel: true))
    ask("swift test", in: first, at: 10, model: model)
    let speech = FloatingRequestPanelModel.speech(of: try #require(panel.requests.first))
    #expect(speech.hasPrefix("Refacto"))
    #expect(speech.contains("swift test"))
  }
}
