import Foundation
import Testing
import VibeApplication
import VibeConversationUI
import VibeDomain

@testable import VibeUI

/// The stub agent signs in at once: the tests drive what happens before and after.
extension WorkspaceProvider: AgentSigningIn {
  func signIn() async -> AgentSignInOutcome { .signedIn }
  func signInRoute() async -> AgentSignInRoute { .browser }

  /// Names no account. Claude Code's says so only once the test lets it, as slow as its CLI.
  func signedInAccount() async -> AgentSignedInAccount? {
    if id == EndpointHarness.claudeCode.providerID {
      await SignInWorkspaceTests.claudeCodeStatus.wait()
    }
    return nil
  }
}

/// #410: a session whose turn stopped because its CLI's sign-in expired.
@MainActor
@Suite("Signing an agent in again from its conversation", .timeLimit(.minutes(2)))
struct SignInWorkspaceTests {
  /// Holds what an agent registered as Claude Code says of its account.
  nonisolated static let claudeCodeStatus = ProbeGate()

  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-sign-in-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func running(
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor()
  ) async throws -> (AppModel, WorkSession) {
    let (model, sessions) = try await runningSessions(supervisor: supervisor)
    return (model, sessions[0])
  }

  /// `count` sessions of the first of `providers`, running.
  private func runningSessions(
    _ count: Int = 1, providers: [WorkspaceProvider] = [WorkspaceProvider()],
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor()
  ) async throws -> (AppModel, [WorkSession]) {
    let sessions = (0..<count).map { index in
      WorkSession(
        name: index == 0 ? "Audit deps" : "Audit deps \(index + 1)",
        initialPrompt: "Audit the dependencies.",
        agent: SessionAgentConfiguration(
          providerID: providers[0].id, resumeIdentifier: "kept-identifier"),
        status: .closed,
        createdAt: Date(timeIntervalSince1970: 1_699_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        closedAt: Date(timeIntervalSince1970: 1_700_000_000),
        repositories: [RepositoryContext(path: folder())]
      )
    }
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: providers)
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.refreshAgents()
    for session in sessions {
      let path = try #require(RestartSession.workingDirectoryPath(of: session))
      let plan = try await providers[0].launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: path))
      await launcher.launch(session: session, plan: plan)
    }
    await model.reload()
    await model.loadSigningInAgents()
    return (model, sessions)
  }

  /// Waits for what a step that goes on by itself leaves, as long as a slow machine may need.
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// The question about the account, whenever it was asked.
  private func question(_ progress: AgentSignInProgress?) -> AgentSignInProgress? {
    guard case .otherAccount(let expected, let actual, let detail, _, let awaited)? = progress
    else { return progress }
    return .otherAccount(
      expected: expected, actual: actual, detail: detail, at: .distantPast, awaited: awaited)
  }

  /// The turn stopped on `StopFailure`, its error `authentication_failed`.
  private func stoppedOnSignIn(_ id: SessionID) -> AgentActivityState {
    AgentActivityMachine.reduce(
      AgentActivityState(activity: .working, source: .structured),
      .signal(
        .turnFailed(
          AgentTerminalPrompt(
            kind: .account, message: "Login expired · Please run /login",
            error: "authentication_failed"))),
      context: AgentActivityContext(
        now: Date(), isVisible: true, requestID: AgentRequestID(sessionID: id, key: "l1")))
  }

  @Test("Sign In is offered, a failure says so, and a session left waiting can be resumed")
  func signInStates() async throws {
    let (model, subject) = try await running()
    #expect(model.signInNotice(for: subject.id) == nil)

    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)
    #expect(model.signInNotice(for: subject.id)?.state == .expired)

    await model.signInEnded(AgentProviderID("stub"), outcome: .notSignedIn(detail: "No browser"))
    #expect(model.signInNotice(for: subject.id)?.state == .failed(detail: "No browser"))

    // Signed in: this session's screen shows no prompt that can be read, which may hold text —
    // so it is not resumed by itself. It waits, Resume offered.
    await model.signInEnded(AgentProviderID("stub"), outcome: .signedIn)
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .signedIn(canResume: true, waiting: .text(nil)))
    #expect(model.resumingAfterSignIn.isEmpty)
  }

  /// Claude Code's prompt as it draws it, holding what the user typed before signing in again.
  private static let promptHoldingText = Array(
    """
    ────────────────────────────────────────\r
    ❯ c'est déployé\r
    ────────────────────────────────────────\r
      ⏵⏵ auto mode on (shift+tab to cycle)\r

    """.utf8)

  @Test("Signed in to another account, nothing resumes until the user says (#478)")
  func anotherAccount() async throws {
    let supervisor = WorkspaceSupervisor()
    let (model, subject) = try await running(supervisor: supervisor)
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)
    let stub = AgentProviderID("stub")
    let started = await supervisor.startCount

    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: "perso@x.io")
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .otherAccount(expected: "pro@x.io", actual: "perso@x.io"))
    #expect(await supervisor.startCount == started)
    // Whatever the CLI says before a second try, the expected account stays the first.
    #expect(model.signedInAccounts.account(of: stub) == "pro@x.io")

    model.keepSignedInAccount(of: stub)
    #expect(model.signedInAccounts.account(of: stub) == "perso@x.io")
    #expect(model.signIns[stub] == nil)
    // From there it is the sign-in of #410: this screen's prompt cannot be read, so Resume is offered.
    await model.reload()
    let deadline = ContinuousClock.now + .seconds(10)
    while model.signInNotice(for: subject.id)?.state != .signedIn(canResume: true, waiting: .text(nil)),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .signedIn(canResume: true, waiting: .text(nil)))
    #expect(await supervisor.startCount == started)
  }

  @Test("A question no session waits on goes with its page, or with the next expiry (#478)")
  func questionDoesNotOutliveItsSignIn() async throws {
    let (model, subject) = try await running()
    let stub = AgentProviderID("stub")
    // Changed on purpose from the settings, no session waiting: the page left, nothing is asked.
    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: "perso@x.io")
    #expect(model.signIns[stub] != nil)
    model.leaveSignIn(of: stub)
    #expect(model.signIns[stub] == nil)

    // The page kept open: a sign-in that expires after it is told as one, and the question goes.
    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: "perso@x.io")
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)
    #expect(model.signInNotice(for: subject.id)?.state == .expired)
    model.publishSignIn(for: subject.id)
    #expect(model.signIns[stub] == nil)

    // Asked of a session stopped on its sign-in: the page left, its conversation still asks.
    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: "perso@x.io")
    model.leaveSignIn(of: stub)
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .otherAccount(expected: "pro@x.io", actual: "perso@x.io"))
  }

  /// Two sessions at work when the sign-in expired: the first stops, is signed in again — to
  /// another account —; the second, started on the old token, stops after that, and the first is
  /// typed into again. None of them resumes on that account unasked.
  @Test("A session stopping on its sign-in after the question joins it (#478)")
  func laterExpiryJoinsTheQuestion() async throws {
    let (model, sessions) = try await runningSessions(2)
    let (first, second) = (sessions[0].id, sessions[1].id)
    let stub = AgentProviderID("stub")
    model.activityCells.set(stoppedOnSignIn(first), for: first)
    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: "perso@x.io")

    model.activityCells.set(stoppedOnSignIn(second), for: second)
    model.publishSignIn(for: second)
    model.activityCells.set(stoppedOnSignIn(first), for: first)
    model.publishSignIn(for: first)

    #expect(model.signIns[stub] != nil)
    for id in [first, second] {
      #expect(
        model.signInNotice(for: id)?.state
          == .otherAccount(expected: "pro@x.io", actual: "perso@x.io"))
    }
  }

  @Test("A page left before the CLI said how it is signed in changes nothing (#478)")
  func cancelledReading() async throws {
    let (model, _) = try await running()
    let stub = AgentProviderID("stub")
    model.signInRoutes[stub] = (.elsewhere, Date())
    model.signedInAddresses[stub] = "pro@x.io"
    let reading = Task { await model.refreshSignedInAccount(of: stub) }
    reading.cancel()
    await reading.value
    #expect(model.signInRoutes[stub]?.route == .elsewhere)
    #expect(model.signedInAddresses[stub] == "pro@x.io")
  }

  @Test("An account signed in to the account of another agent of its CLI is told so (#478)")
  func sameAccountAsAnotherAgent() async throws {
    let (model, _) = try await running()
    let account = AgentAccount(
      name: "Claude 2", harness: .claudeCode, configurationDirectory: "~/.claude-2")
    model.agentAccounts = AgentAccountsSettingsModel(
      repository: InMemoryAgentAccountRepository([account]), home: "/Users/someone",
      defaultDirectories: [:])
    let added = AgentProviderID(account.providerID)
    model.signedInAccounts.remember("pro@x.io", of: AgentProviderID("claude-code"))

    await model.signInEnded(added, outcome: .signedIn, after: "Pro@x.io")
    try await waitUntil { model.signIns[added] != nil }
    #expect(model.signIns[added] == .sameAccount(as: "claude-code"))
    model.leaveSignIn(of: added)
    #expect(model.signIns[added] == nil)
  }

  /// Each other agent's CLI is asked in turn, seconds each (#478).
  @Test("The sessions resume before the other agents of the CLI have said their account")
  func sameAccountCheckDoesNotHoldBackResuming() async throws {
    let account = AgentAccount(
      name: "Claude 2", harness: .claudeCode, configurationDirectory: "~/.claude-2")
    let (model, sessions) = try await runningSessions(
      providers: [
        WorkspaceProvider(id: account.providerID),
        WorkspaceProvider(id: EndpointHarness.claudeCode.providerID, name: "Claude Code"),
      ])
    let subject = sessions[0].id
    model.agentAccounts = AgentAccountsSettingsModel(
      repository: InMemoryAgentAccountRepository([account]), home: "/Users/someone",
      defaultDirectories: [:])
    let added = AgentProviderID(account.providerID)
    model.signedInAccounts.remember("pro@x.io", of: AgentProviderID("claude-code"))
    model.activityCells.set(stoppedOnSignIn(subject), for: subject)

    // Claude Code has not said yet: the session is looked at all the same — Resume offered, as
    // its screen shows no prompt that can be read.
    let ending = Task { await model.signInEnded(added, outcome: .signedIn, after: "pro@x.io") }
    let resumable = ConversationSignIn.State.signedIn(canResume: true, waiting: .text(nil))
    try await waitUntil { model.signInNotice(for: subject)?.state == resumable }
    #expect(model.signInNotice(for: subject)?.state == resumable)

    await Self.claudeCodeStatus.open()
    await ending.value
    try await waitUntil { model.signIns[added] != nil }
    #expect(model.signIns[added] == .sameAccount(as: "Claude Code"))
  }

  @Test("An account changed outside the application is not taken for a mistake (#478)")
  func changedOutside() async throws {
    let (model, _) = try await running()
    let stub = AgentProviderID("stub")
    model.signedInAccounts.remember("old@x.io", of: stub)
    await model.signInEnded(stub, outcome: .signedIn, before: "new@x.io", after: "new@x.io")
    #expect(model.signIns[stub] == nil)
    #expect(model.signedInAccounts.account(of: stub) == "new@x.io")
  }

  @Test("A plan or a name that changed is the same account, another organization is not (#478)")
  func organizations() async throws {
    let (model, _) = try await running()
    let stub = AgentProviderID("stub")
    let max = AgentSignedInAccount(label: "a@x.io · Max", email: "a@x.io", organizationID: "1")
    let ultra = AgentSignedInAccount(label: "a@x.io · Ultra", email: "a@x.io", organizationID: "1")
    let team = AgentSignedInAccount(label: "a@x.io · Team", email: "a@x.io", organizationID: "2")
    await model.signInEnded(stub, outcome: .signedIn, before: max, after: ultra)
    #expect(model.signIns[stub] == nil)
    await model.signInEnded(stub, outcome: .signedIn, before: ultra, after: team)
    #expect(
      question(model.signIns[stub])
        == .otherAccount(expected: ultra, actual: team, at: .distantPast, awaited: false))
  }

  @Test("An account that cannot be read after signing in resumes nothing (#478)")
  func unreadableAccount() async throws {
    let (model, _) = try await running()
    let stub = AgentProviderID("stub")
    await model.signInEnded(stub, outcome: .signedIn, before: "pro@x.io", after: nil)
    #expect(
      question(model.signIns[stub])
        == .otherAccount(expected: "pro@x.io", actual: nil, at: .distantPast, awaited: false))
    model.keepSignedInAccount(of: stub)
    #expect(model.signIns[stub] == nil)
    #expect(model.signedInAccounts.account(of: stub) == nil)
  }

  @Test("Signed in to the same account, or by a CLI that names none, it resumes (#478)")
  func sameAccount() async throws {
    let (model, _) = try await running()
    let stub = AgentProviderID("stub")
    await model.signInEnded(stub, outcome: .signedIn, before: "Pro@x.io", after: "pro@x.io")
    #expect(model.signIns[stub] == nil)
    model.signedInAccounts.remember(nil, of: stub)
    await model.signInEnded(stub, outcome: .signedIn)
    #expect(model.signIns[stub] == nil)
  }

  @Test("Text left in the prompt is shown, and Resume sends it once the agent is restarted")
  func textWaitingIsSent() async throws {
    let supervisor = WorkspaceSupervisor(history: Self.promptHoldingText)
    let (model, subject) = try await running(supervisor: supervisor)
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)

    // Not sent by itself: the user may not be done with it.
    await model.signInEnded(AgentProviderID("stub"), outcome: .signedIn)
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .signedIn(canResume: true, waiting: .text("c'est déployé")))
    #expect(await supervisor.startCount == 1)

    // Text other than the one shown is not sent: the notice shows what the prompt holds now.
    model.resumingAfterSignIn.insert(subject.id)
    await model.resumeSignedIn(subject.id, sending: "c'est fait")
    #expect(
      model.signInNotice(for: subject.id)?.state
        == .signedIn(canResume: true, waiting: .text("c'est déployé")))
    #expect(await supervisor.startCount == 1)

    model.resumeAfterSignIn(subject.id)
    #expect(model.signInNotice(for: subject.id)?.state == .resuming)
    let deadline = ContinuousClock.now + .seconds(30)
    while await supervisor.startCount < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await supervisor.startCount == 2)
    let arguments = await supervisor.lastSpec?.arguments.joined(separator: " ") ?? ""
    #expect(arguments.contains("kept-identifier"))
    // The restarted agent is not waited for: what is typed into it is the update suite's.
    await supervisor.finish(id: subject.id, state: .exited(code: 0))
  }

  @Test("A failure is not shown over a sign-in that expired after it")
  func oldFailureIsForgotten() async throws {
    let (model, subject) = try await running()
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)
    await model.signInEnded(AgentProviderID("stub"), outcome: .notSignedIn(detail: nil))
    #expect(model.signInNotice(for: subject.id)?.state == .failed(detail: nil))

    try await Task.sleep(for: .milliseconds(20))
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)

    #expect(model.signInNotice(for: subject.id)?.state == .expired)
  }

  /// #419: the browser signs a subscription in; another account is the terminal's, and a key
  /// or a provider set outside the CLI is no one's here.
  @Test("Sign In is only offered for an account the browser signs in")
  func signInRoutes() async throws {
    let (model, subject) = try await running()
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)
    let stub = AgentProviderID("stub")
    // Until the CLI has said, the terminal only.
    #expect(model.signInNotice(for: subject.id)?.route == .unknown)
    model.signIn(from: subject.id)
    #expect(model.signIns[stub] == nil)

    // The stub's own answer, once looked up: it would otherwise come over the ones set here.
    model.publishSignIns()
    let deadline = ContinuousClock.now + .seconds(30)
    while model.signInRoutes[stub] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.signInNotice(for: subject.id)?.route == .browser)

    model.signInRoutes[stub] = (.terminal, Date())
    #expect(model.signInNotice(for: subject.id)?.route == .terminal)
    model.signIn(from: subject.id)
    #expect(model.signIns[stub] == nil)

    model.signInRoutes[stub] = (.elsewhere, Date())
    #expect(model.signInNotice(for: subject.id)?.route == .elsewhere)
    #expect(model.signInNotice(for: subject.id)?.state == .expired)
  }

  @Test("A cancelled sign-in goes back to offering it")
  func cancelledSignIn() async throws {
    let (model, subject) = try await running()
    model.activityCells.set(stoppedOnSignIn(subject.id), for: subject.id)

    await model.signInEnded(AgentProviderID("stub"), outcome: .cancelled)

    #expect(model.signInNotice(for: subject.id)?.state == .expired)
  }
}
