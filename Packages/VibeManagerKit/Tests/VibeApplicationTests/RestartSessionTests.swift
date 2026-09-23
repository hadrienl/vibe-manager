import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Restarting a closed session")
struct RestartSessionTests {
  // MARK: - Fixtures

  private func session(
    status: SessionStatus = .closed,
    closedAt: Date? = Date(timeIntervalSince1970: 1_700_000_100),
    providerID: String? = "stub",
    resumeIdentifier: String? = "0f7e6d5c-4b3a-2190-8765-43210fedcba9",
    prompt: String = "Split the signature check out.",
    repositories: [RepositoryContext] = [RepositoryContext(rootPath: "/work/app")]
  ) -> WorkSession {
    WorkSession(
      name: "Refactor the webhook",
      initialPrompt: prompt,
      agent: providerID.map {
        SessionAgentConfiguration(
          providerID: $0, modelID: "fast", resumeIdentifier: resumeIdentifier)
      },
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: closedAt,
      archivedAt: status == .archived ? Date(timeIntervalSince1970: 1_700_000_100) : nil,
      repositories: repositories,
      notes: "The retry path is still untested."
    )
  }

  /// A session as `CreateSession` actually stores one, before any agent has run in it.
  ///
  /// Built from the draft rather than assembled by hand: a stored session is never `closedAt:
  /// nil` — that shape only exists while a session is running — and a fixture that invented it
  /// tested a state the store cannot hold.
  private func neverStartedSession(prompt: String = "Split the signature check out.")
    -> WorkSession
  {
    SessionDraft(
      name: "Refactor the webhook",
      initialPrompt: prompt,
      providerID: "stub",
      modelID: "fast",
      workingDirectoryPath: "/work/app"
    )
    .session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
  }

  private func makeSubject(
    session: WorkSession,
    provider: RestorationProvider = RestorationProvider(),
    folder: WorkingDirectoryStatus = .usable
  ) -> (RestartSession, SpyRepository) {
    let repository = SpyRepository(sessions: [session])
    let restart = RestartSession(
      repository: repository,
      agents: RestorationRegistry(providers: [provider]),
      folders: RestorationFolders(status: folder)
    )
    return (restart, repository)
  }

  /// The refusal a restart answers with, for the tests that hold each one to its wording.
  ///
  /// The use case throws its refusals rather than offering them, so that nothing can ask what
  /// would go wrong at the price of a detection and a launch plan it then discards.
  private func refusal(
    from restart: RestartSession,
    for id: SessionID
  ) async -> SessionRestartRefusal? {
    do {
      _ = try await restart(id: id)
      return nil
    } catch let refusal as SessionRestartRefusal {
      return refusal
    } catch {
      return .storeUnreadable
    }
  }

  // MARK: - Choosing the mode

  @Test("A session with a resumable conversation resumes it, and is handed no prompt")
  func resumesNatively() async throws {
    let (restart, repository) = makeSubject(session: session())

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.mode == .native(identifier: "0f7e6d5c-4b3a-2190-8765-43210fedcba9"))
    #expect(outcome.explanation == nil)
    #expect(outcome.plan.promptDelivery == .none)
    #expect(!outcome.needsConfirmation)
    #expect(await repository.writes == 0)
  }

  @Test("A session that never ran gets the launch it never had, prompt and all")
  func firstLaunchKeepsTheInitialPrompt() async throws {
    let (restart, repository) = makeSubject(session: neverStartedSession())

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.mode == .firstLaunch)
    #expect(outcome.plan.promptDelivery == .argument)
    #expect(!outcome.needsConfirmation)
  }

  @Test("A stale identifier on a session that never ran does not fake a conversation to resume")
  func neverStartedIgnoresAStoredIdentifier() async throws {
    var subject = neverStartedSession()
    subject.agent?.resumeIdentifier = "0f7e6d5c-4b3a-2190-8765-43210fedcba9"
    let (restart, repository) = makeSubject(session: subject)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.mode == .firstLaunch)
    #expect(outcome.explanation == nil)
  }

  @Test("Without an identifier, a new process is proposed with a summary and an explanation")
  func fallsBackToASummary() async throws {
    let (restart, repository) = makeSubject(session: session(resumeIdentifier: nil))

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.needsConfirmation)
    #expect(outcome.explanation == .noResumeIdentifier(agentName: "Stub Agent"))
    let brief = try #require(outcome.mode.brief)
    #expect(brief.text.contains("Refactor the webhook"))
    #expect(outcome.plan.promptDelivery == .argument)
  }

  @Test("An agent that cannot resume says so, rather than failing the restart")
  func agentWithoutResume() async throws {
    let provider = RestorationProvider(
      capabilities: AgentCapabilities(supportsModelSelection: true, supportsInitialPrompt: true)
    )
    let (restart, repository) = makeSubject(session: session(), provider: provider)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.explanation == .agentCannotResume(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("An identifier the CLI would refuse falls back instead of stopping the restart")
  func rejectedIdentifierFallsBack() async throws {
    let provider = RestorationProvider(resumeFailure: .missingResumeIdentifier)
    let (restart, repository) = makeSubject(session: session(), provider: provider)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.explanation == .identifierRejected(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("Asked to ignore the conversation, it is not even offered to the agent")
  func ignoringTheIdentifier() async throws {
    let (restart, repository) = makeSubject(session: session())

    let outcome = try await restart(
      id: repository.stored[0].id,
      skippingResume: .alreadyAnswered
    )

    #expect(outcome.explanation == .resumeDeclined(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("A conversation the agent dropped last time is not handed back, and the summary says so")
  func skippingAResumeThatFailedBefore() async throws {
    let (restart, repository) = makeSubject(session: session())

    let outcome = try await restart(
      id: repository.stored[0].id,
      skippingResume: .failedLastTime
    )

    #expect(outcome.explanation == .resumeFailedBefore(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("An agent that takes no prompt is restarted without one, and the user is told")
  func agentWithoutPrompt() async throws {
    let provider = RestorationProvider(capabilities: AgentCapabilities())
    let (restart, repository) = makeSubject(session: session(), provider: provider)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.mode == .freshWithoutContext)
    #expect(outcome.plan.promptDelivery == .none)
    #expect(outcome.needsConfirmation)
  }

  @Test("An emptied summary starts a process with nothing, and says so")
  func emptiedSummaryIsNotAnnouncedAsOne() async throws {
    let (restart, repository) = makeSubject(session: session(resumeIdentifier: nil))

    let outcome = try await restart(id: repository.stored[0].id, contextOverride: "   \n  ")

    // Clearing the field is a real answer — start it again, tell it nothing — but the mode must
    // not keep claiming a summary was handed over.
    #expect(outcome.mode == .freshWithoutContext)
    #expect(outcome.plan.promptDelivery == .none)
  }

  @Test("An edited summary is what gets sent, within the same ceiling")
  func editedSummaryIsUsed() async throws {
    let (restart, repository) = makeSubject(session: session(resumeIdentifier: nil))

    let outcome = try await restart(
      id: repository.stored[0].id,
      contextOverride: "Carry on with the retry path."
    )

    #expect(outcome.mode.brief?.text == "Carry on with the retry path.")
  }

  // MARK: - Fidelity

  @Test("The plan is rebuilt from the session: same agent, same model, same folder")
  func planFollowsTheSession() async throws {
    let subject = session(
      repositories: [
        RepositoryContext(
          rootPath: "/work/app",
          mode: .worktree,
          worktreePath: "/work/app-hotfix",
          branchName: "vibe/hotfix"
        )
      ]
    )
    let (restart, repository) = makeSubject(session: subject)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.plan.providerID == AgentProviderID("stub"))
    #expect(outcome.plan.arguments.contains("fast"))
    // The recorded worktree, not the repository root: that is where the work was left.
    #expect(outcome.plan.workingDirectoryPath == "/work/app-hotfix")
  }

  // MARK: - Refusals

  @Test("An archived session is refused, and pointed at unarchiving")
  func archivedIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(status: .archived))
    let id = repository.stored[0].id

    let answer = await refusal(from: restart, for: id)

    #expect(answer == .notRestartable(.archived))
    #expect(answer?.recoverySuggestion == "Unarchive it first, then restart it.")
    #expect(await repository.writes == 0)
  }

  @Test("A running session has nothing to restart")
  func activeIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(status: .active, closedAt: nil))

    #expect(await refusal(from: restart, for: repository.stored[0].id) == .notRestartable(.active))
    #expect(await repository.writes == 0)
  }

  @Test("An agent that is not installed any more stops the restart, with its name")
  func unknownAgentIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(providerID: "gone"))

    #expect(await refusal(from: restart, for: repository.stored[0].id) == .agentUnknown("gone"))
    #expect(await repository.writes == 0)
  }

  @Test("An agent that cannot run right now stops the restart, with its remedy")
  func unavailableAgentIsRefused() async throws {
    let (restart, repository) = makeSubject(
      session: session(),
      provider: RestorationProvider(state: .notFound)
    )

    guard case .agentUnavailable = await refusal(from: restart, for: repository.stored[0].id) else {
      Issue.record("An unusable agent must refuse the restart")
      return
    }
    #expect(await repository.writes == 0)
  }

  @Test("A folder that disappeared is caught before a terminal is ever opened")
  func missingFolderIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(), folder: .missing)

    #expect(
      await refusal(from: restart, for: repository.stored[0].id)
        == .workingDirectoryUnusable(path: "/work/app", status: .missing)
    )
    #expect(await repository.writes == 0)
  }

  @Test("A session without a folder is refused rather than started somewhere arbitrary")
  func noFolderIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(repositories: []))

    #expect(await refusal(from: restart, for: repository.stored[0].id) == .noRepository)
    #expect(await repository.writes == 0)
  }

  @Test("A session that is gone from the store is refused")
  func missingSessionIsRefused() async throws {
    let (restart, _) = makeSubject(session: session())

    #expect(await refusal(from: restart, for: SessionID()) == .sessionMissing)
  }

  @Test("A launch the agent refuses is reported as such, and writes nothing")
  func launchRejectionIsReported() async throws {
    let provider = RestorationProvider(
      launchFailure: .promptTooLarge(byteCount: 40_000, limit: 16_384))
    let (restart, repository) = makeSubject(
      session: session(resumeIdentifier: nil),
      provider: provider
    )

    let answer = await refusal(from: restart, for: repository.stored[0].id)

    #expect(
      answer == .launchRejected(.promptTooLarge(byteCount: 40_000, limit: 16_384))
    )
    #expect(await repository.writes == 0)
  }

  @Test("Nothing is written to the store by preparing a restart")
  func preparingWritesNothing() async throws {
    let (restart, repository) = makeSubject(session: session())

    _ = try await restart(id: repository.stored[0].id)

    #expect(await repository.writes == 0)
    #expect(repository.stored[0].status == .closed)
  }
}

// MARK: - Doubles

private actor SpyRepository: SessionRepository {
  nonisolated let stored: [WorkSession]
  private var sessionsByID: [SessionID: WorkSession]
  private(set) var writes = 0

  init(sessions: [WorkSession]) {
    stored = sessions
    sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
  }

  func sessions() throws -> [WorkSession] { Array(sessionsByID.values) }

  func session(id: SessionID) throws -> WorkSession? { sessionsByID[id] }

  func save(_ session: WorkSession) throws {
    writes += 1
    sessionsByID[session.id] = session
  }

  func mutate(
    id: SessionID,
    _ transform: @Sendable (inout WorkSession) throws -> Void
  ) throws -> WorkSession? {
    guard var session = sessionsByID[id] else { return nil }
    try transform(&session)
    writes += 1
    sessionsByID[id] = session
    return session
  }
}
