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
}

/// #410: a session whose turn stopped because its CLI's sign-in expired.
@MainActor
@Suite("Signing an agent in again from its conversation", .timeLimit(.minutes(2)))
struct SignInWorkspaceTests {
  private func folder() -> String {
    let path = NSTemporaryDirectory().appending("vibe-sign-in-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func running(
    supervisor: WorkspaceSupervisor = WorkspaceSupervisor()
  ) async throws -> (AppModel, WorkSession) {
    let subject = WorkSession(
      name: "Audit deps",
      initialPrompt: "Audit the dependencies.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept-identifier"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: folder())]
    )
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.refreshAgents()
    let path = try #require(RestartSession.workingDirectoryPath(of: subject))
    let plan = try await WorkspaceProvider().launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    await model.reload()
    await model.loadSigningInAgents()
    return (model, subject)
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
