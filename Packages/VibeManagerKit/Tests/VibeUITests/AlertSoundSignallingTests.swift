import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
private final class PostingNotifier: RequestNotifying {
  private(set) var posted: [RequestNotification] = []

  func post(_ notification: RequestNotification) { posted.append(notification) }
  func remove(_ ids: [AgentRequestID]) {}
  func setBadge(_ count: Int?) {}
  func isAuthorized() async -> Bool? { true }
}

/// When a session out of sight needs the user, the alert sound plays where no notification
/// carries it (#393).
@MainActor
@Suite("The alert sound of a request (#393)")
struct AlertSoundSignallingTests {
  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name, initialPrompt: "Do \(name)", agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active, createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1), repositories: [], taskStatus: .doing)
  }

  private func makeModel(_ sessions: [WorkSession], floating: Bool = false) async -> (
    AppModel, RecordingSoundPlayer, PostingNotifier
  ) {
    let model = AppModel(
      repository: WorkspaceRepository(sessions: sessions),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    let player = RecordingSoundPlayer()
    let sounds = AlertSoundLibraryModel(
      library: InMemoryAlertSoundLibrary(), preferences: InMemoryAlertSoundPreferences(),
      player: player, systemSoundsDirectory: nil)
    sounds.announce = { _ in }
    model.alertSounds = sounds
    model.floatingPanel = FloatingRequestPanelModel(
      preferences: InMemoryFloatingPanelPreferences(showsFloatingPanel: floating))
    let notifier = PostingNotifier()
    model.requestNotifier = notifier
    return (model, player, notifier)
  }

  private func ask(_ command: String, in session: WorkSession, model: AppModel) {
    let id = AgentRequestID(sessionID: session.id, key: command)
    var state = model.activities[session.id] ?? AgentActivityState(source: .structured)
    state.activity = .awaitingUser(.approval)
    state.requests.append(
      AgentRequest(
        id: id, receivedAt: Date(timeIntervalSince1970: 10), kind: .approval,
        content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
        reference: AgentToolReference(tool: "Bash", subject: command), isShown: true))
    model.activities[session.id] = state
    model.requestAnswering[id] = .fromPalette([.allowOnce, .deny])
    model.requestsDidChange()
  }

  @Test("In front, a request of another session sounds; one of the session on screen does not")
  func inFront() async {
    let first = session("First")
    let second = session("Second")
    let (model, player, notifier) = await makeModel([first, second])
    model.select(first.id)
    ask("ls", in: first, model: model)
    #expect(player.count == 0)
    ask("make", in: second, model: model)
    #expect(player.systemAlerts == 1)
    #expect(notifier.posted.isEmpty)
  }

  @Test("Switching sessions makes no sound for a request already there")
  func switching() async {
    let first = session("First")
    let second = session("Second")
    let (model, player, _) = await makeModel([first, second])
    model.select(first.id)
    ask("ls", in: first, model: model)
    model.select(second.id)
    #expect(player.count == 0)
  }

  @Test("In the background, the notification carries the sound: none is played here")
  func background() async {
    let first = session("First")
    let (model, player, notifier) = await makeModel([first])
    model.select(nil)
    model.applicationWillResignActive()
    ask("ls", in: first, model: model)
    #expect(notifier.posted.count == 1)
    #expect(player.count == 0)
  }

  @Test("In the background with the floating panel, no notification: the sound plays here")
  func floating() async {
    let first = session("First")
    let (model, player, notifier) = await makeModel([first], floating: true)
    model.select(nil)
    model.applicationWillResignActive()
    ask("ls", in: first, model: model)
    #expect(notifier.posted.isEmpty)
    #expect(player.systemAlerts == 1)
  }

  @Test("In the background with the notifications turned off: silence")
  func silenced() async {
    let first = session("First")
    let (model, player, notifier) = await makeModel([first])
    model.notifiesRequests = false
    model.select(nil)
    model.applicationWillResignActive()
    ask("ls", in: first, model: model)
    #expect(notifier.posted.isEmpty)
    #expect(player.count == 0)
  }

  @Test("In front with the notifications turned off and no floating panel: silence as well")
  func silencedInFront() async {
    let first = session("First")
    let second = session("Second")
    let (model, player, _) = await makeModel([first, second])
    model.notifiesRequests = false
    model.select(first.id)
    ask("make", in: second, model: model)
    #expect(player.count == 0)
  }

  @Test("Requests read back at launch were there before: no sound")
  func restored() async {
    let first = session("First")
    let second = session("Second")
    let (model, player, _) = await makeModel([first, second])
    model.select(first.id)
    model.isReadingRestoredRequests = true
    ask("make", in: second, model: model)
    model.isReadingRestoredRequests = false
    #expect(player.count == 0)
    ask("ls", in: second, model: model)
    #expect(player.systemAlerts == 1)
  }

  @Test("The main window hidden, a request of the selected session sounds")
  func windowHidden() async {
    let first = session("First")
    let (model, player, _) = await makeModel([first])
    model.select(first.id)
    model.mainWindowVisibilityChanged(false)
    ask("ls", in: first, model: model)
    #expect(player.systemAlerts == 1)
  }
}
