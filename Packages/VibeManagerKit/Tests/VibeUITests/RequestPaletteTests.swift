import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

/// What the palette would notify, recorded.
@MainActor
private final class RecordingNotifier: RequestNotifying {
  private(set) var posted: [RequestNotification] = []
  private(set) var removed: [AgentRequestID] = []
  private(set) var badge: Int??

  func post(_ notification: RequestNotification) {
    posted.append(notification)
  }

  func remove(_ ids: [AgentRequestID]) {
    removed += ids
  }

  func setBadge(_ count: Int?) {
    badge = .some(count)
  }

  func isAuthorized() async -> Bool? {
    true
  }
}

@MainActor
@Suite("The palette of pending requests")
struct RequestPaletteTests {
  private func session(_ name: String, in column: SessionTaskStatus = .doing) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub"),
      status: .active,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      repositories: [
        RepositoryContext(
          path: "/work/\(name.lowercased())",
          git: GitSnapshot(
            repositoryRootPath: "/work/\(name.lowercased())", branchName: "feat/\(name)",
            isDirty: false))
      ],
      taskStatus: column
    )
  }

  private func makeModel(_ sessions: [WorkSession]) async -> AppModel {
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let model = AppModel(repository: repository, agents: registry)
    await model.load()
    return model
  }

  /// The session's agent asks to run `command`, received at `seconds`.
  private func ask(
    _ command: String, in session: WorkSession, at seconds: TimeInterval, model: AppModel,
    answering: AgentRequestAnswering = .fromPalette([.allowOnce, .deny])
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
    model.requestAnswering[id] = answering
    model.requestsDidChange()
    return id
  }

  private func settle(_ session: WorkSession, model: AppModel) {
    model.activities[session.id]?.requests.removeFirst()
    model.requestsDidChange()
  }

  @Test("Requests of other sessions are listed oldest first, with whose they are")
  func listed() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(nil)
    _ = ask("make", in: second, at: 20, model: model)
    _ = ask("ls", in: first, at: 10, model: model)

    let pending = model.pendingRequests
    #expect(pending.map(\.session.name) == ["First", "Second"])
    #expect(pending[0].folderName == "first")
    #expect(pending[0].branch == "feat/First")
    #expect(pending[0].agentName == (model.agentNames["stub"] ?? "stub"))
  }

  @Test("The session on screen answers its own requests: they leave the palette, and come back")
  func foreground() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(second.id)
    _ = ask("ls", in: first, at: 10, model: model)
    _ = ask("make", in: second, at: 20, model: model)
    #expect(model.pendingRequests.map(\.session.id) == [first.id])

    model.select(first.id)
    #expect(model.pendingRequests.map(\.session.id) == [second.id])
  }

  @Test("Requests of every column are listed, not only the one on screen")
  func everyColumn() async {
    let doing = session("Doing")
    let done = session("Done", in: .done)
    let model = await makeModel([doing, done])
    model.select(doing.id)
    _ = ask("ls", in: done, at: 10, model: model)
    #expect(model.filter.column == .doing)
    #expect(model.pendingRequests.count == 1)
  }

  @Test("Opening a request's session shows its column and selects it")
  func openSession() async {
    let doing = session("Doing")
    let waiting = session("Waiting", in: .waiting)
    let model = await makeModel([doing, waiting])
    model.select(doing.id)
    let id = ask("ls", in: waiting, at: 10, model: model)

    model.openSession(for: id)
    #expect(model.filter.column == .waiting)
    #expect(model.selectedSessionID == waiting.id)
  }

  @Test("Only a request arriving in the background is notified, and taken away once settled")
  func notifications() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(second.id)
    let notifier = RecordingNotifier()
    model.requestNotifier = notifier

    // In front: seen in the palette, not notified.
    _ = ask("ls", in: first, at: 10, model: model)
    #expect(notifier.posted.isEmpty)

    model.applicationWillResignActive()
    #expect(notifier.posted.isEmpty)
    let id = ask("make", in: second, at: 20, model: model)
    #expect(notifier.posted.map(\.id) == [id])
    let posted = notifier.posted[0]
    #expect(posted.title == "Second — \(model.agentNames["stub"] ?? "stub")")
    #expect(posted.offersAllow && posted.offersDeny)
    // The kind of request only, by default: no command on a lock screen.
    #expect(!posted.body.contains("make"))

    model.activities[second.id]?.requests.removeAll()
    model.requestsDidChange()
    #expect(notifier.removed == [id])
  }

  @Test("The command is in the notification only when the user asks for it")
  func detailedNotification() async {
    let first = session("First")
    let model = await makeModel([first])
    model.select(nil)
    let notifier = RecordingNotifier()
    model.requestNotifier = notifier
    model.requestNotificationContent = .detail
    model.applicationWillResignActive()
    _ = ask("make release", in: first, at: 10, model: model)
    #expect(notifier.posted.first?.body.contains("make release") == true)
  }

  @Test("A request that cannot be allowed from outside is not offered Allow in its notification")
  func notificationActions() async {
    let first = session("First")
    let model = await makeModel([first])
    model.select(nil)
    let notifier = RecordingNotifier()
    model.requestNotifier = notifier
    model.applicationWillResignActive()
    _ = ask("big write", in: first, at: 10, model: model, answering: .fromPalette([.deny]))
    #expect(notifier.posted.first?.offersAllow == false)
    #expect(notifier.posted.first?.offersDeny == true)
  }

  @Test("Notifications turned off notify nothing")
  func silenced() async {
    let first = session("First")
    let model = await makeModel([first])
    model.select(nil)
    let notifier = RecordingNotifier()
    model.requestNotifier = notifier
    model.notifiesRequests = false
    model.applicationWillResignActive()
    _ = ask("ls", in: first, at: 10, model: model)
    #expect(notifier.posted.isEmpty)
  }

  @Test("The Dock counts every request, the session on screen's included, and nothing at zero")
  func badge() async {
    let first = session("First")
    let second = session("Second")
    let model = await makeModel([first, second])
    model.select(first.id)
    let notifier = RecordingNotifier()
    model.requestNotifier = notifier
    _ = ask("ls", in: first, at: 10, model: model)
    _ = ask("make", in: second, at: 20, model: model)
    #expect(notifier.badge == .some(2))

    settle(first, model: model)
    settle(second, model: model)
    #expect(notifier.badge == .some(nil))

    model.showsRequestDockBadge = false
    _ = ask("ls", in: first, at: 30, model: model)
    #expect(notifier.badge == .some(nil))
  }

  @Test("A new request is said by VoiceOver, and unfolds the palette only if asked to")
  func announced() async {
    let first = session("First")
    let model = await makeModel([first])
    model.select(nil)
    model.setRequestPaletteCollapsed(true)
    _ = ask("ls", in: first, at: 10, model: model)
    #expect(Announcer.lastAnnouncement?.contains("First") == true)
    #expect(model.isRequestPaletteCollapsed)

    model.expandsPaletteOnRequest = true
    _ = ask("make", in: first, at: 20, model: model)
    #expect(!model.isRequestPaletteCollapsed)
  }

  @Test("A clicked notification's request is shown once, and ⌥⌘P goes to the oldest again")
  func revealed() async {
    let first = session("First")
    let model = await makeModel([first])
    model.select(nil)
    let id = ask("ls", in: first, at: 10, model: model)
    model.revealRequest(id)
    #expect(model.consumeRevealedRequest() == id)
    #expect(model.consumeRevealedRequest() == nil)
  }

  @Test("⌥⌘P unfolds the palette and asks it to take the keyboard")
  func focus() async {
    let model = await makeModel([session("First")])
    model.setRequestPaletteCollapsed(true)
    let before = model.requestPaletteFocusRequest
    model.focusRequestPalette()
    #expect(!model.isRequestPaletteCollapsed)
    #expect(model.requestPaletteFocusRequest == before + 1)
  }
}

@Suite("What an agent wrote, shown")
struct DisplaySafeTextTests {
  @Test("Control characters, escapes, direction changes and invisible characters are named")
  func named() {
    #expect(DisplaySafeText.visible("ls\u{1B}[2K") == "ls␛[2K")
    #expect(DisplaySafeText.visible("a\u{07}b\u{7F}") == "a␇b␡")
    #expect(DisplaySafeText.visible("rm -rf /\u{202E}sl") == "rm -rf /⟨U+202E⟩sl")
    #expect(DisplaySafeText.visible("a\u{200B}b") == "a⟨U+200B⟩b")
    #expect(DisplaySafeText.visible("line\n\tnext") == "line\n\tnext")
    #expect(DisplaySafeText.visible("échec 🙂") == "échec 🙂")
  }
}

@Suite("The words of a request")
struct RequestPresentationTests {
  @Test("Always allowing says what it allows, and for how long")
  func alwaysAllow() {
    let title = String(
      localized: RequestPresentation.alwaysAllowTitle(
        AgentAlwaysAllow(
          rules: [.directories(["/Users/a/dev"]), .mode("acceptEdits")], scope: .session)))
    #expect(title == "Always allow access to dev, file edits for this session")
    let rule = String(
      localized: RequestPresentation.alwaysAllowTitle(
        AgentAlwaysAllow(rules: [.toolRule(tool: "Bash", content: "npm test:*")], scope: .project)))
    #expect(rule == "Always allow Bash(npm test:*) in this project")
  }

  @Test("A notification says the kind of request, or what it asks when the user wants it")
  func notificationBody() {
    let content = AgentRequestContent.permission(
      AgentToolPermission(tool: .shell, toolName: "Bash", subject: "rm -rf build"))
    #expect(
      RequestPresentation.notificationBody(of: content, detail: .kind)
        == "Permission requested: Shell command")
    #expect(
      RequestPresentation.notificationBody(of: content, detail: .detail)
        == "Shell command — rm -rf build")
  }

  @Test("An MCP call without a subject is named by its server and tool")
  func mcp() {
    let content = AgentRequestContent.permission(
      AgentToolPermission(
        tool: .mcp(server: "github", tool: "create_issue"), toolName: "mcp__github__create_issue",
        subject: nil))
    #expect(RequestPresentation.subject(of: content) == "github · create_issue")
    #expect(RequestPresentation.symbolName(of: content) == "puzzlepiece.extension")
  }
}

@Suite("The words of a request, in French")
struct RequestPresentationLocalizationTests {
  @Test("Titles, reasons for the terminal, and a count of questions")
  func french() {
    #expect(
      Localization.string(RequestPresentation.toolTitle(.shell), in: "fr") == "Commande shell")
    #expect(
      Localization.string(
        RequestPresentation.terminalReason(.uncertain, isQuestion: false), in: "fr")
        == "Plusieurs demandes attendent dans cette session\u{00A0}: répondez dans la session.")
    let two = AgentRequestContent.questions([
      AgentQuestion(header: nil, text: "a", options: []),
      AgentQuestion(header: nil, text: "b", options: []),
    ])
    #expect(Localization.string(RequestPresentation.title(of: two), in: "fr") == "2 questions")
    #expect(Localization.string(RequestPresentation.title(of: two), in: "en") == "2 questions")
  }
}
