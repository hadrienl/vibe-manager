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
    repositories: [RepositoryContext] = [RepositoryContext(path: "/work/app")]
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

  private func makeSubject(
    session: WorkSession,
    provider: StubProvider = StubProvider(),
    folder: WorkingDirectoryStatus = .usable
  ) -> (RestartSession, SpyRepository) {
    let repository = SpyRepository(sessions: [session])
    let restart = RestartSession(
      repository: repository,
      agents: StubRegistry(providers: [provider]),
      folders: StubFolders(status: folder)
    )
    return (restart, repository)
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
    let subject = session(closedAt: nil, resumeIdentifier: nil)
    let (restart, repository) = makeSubject(session: subject)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.mode == .firstLaunch)
    #expect(outcome.plan.promptDelivery == .argument)
    #expect(!outcome.needsConfirmation)
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
    let provider = StubProvider(
      capabilities: AgentCapabilities(supportsModelSelection: true, supportsInitialPrompt: true)
    )
    let (restart, repository) = makeSubject(session: session(), provider: provider)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.explanation == .agentCannotResume(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("An identifier the CLI would refuse falls back instead of stopping the restart")
  func rejectedIdentifierFallsBack() async throws {
    let provider = StubProvider(resumeFailure: .missingResumeIdentifier)
    let (restart, repository) = makeSubject(session: session(), provider: provider)

    let outcome = try await restart(id: repository.stored[0].id)

    #expect(outcome.explanation == .identifierRejected(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("Asked to ignore the conversation, it is not even offered to the agent")
  func ignoringTheIdentifier() async throws {
    let (restart, repository) = makeSubject(session: session())

    let outcome = try await restart(id: repository.stored[0].id, ignoringResumeIdentifier: true)

    #expect(outcome.explanation == .resumeDeclined(agentName: "Stub Agent"))
    #expect(outcome.mode.brief != nil)
  }

  @Test("An agent that takes no prompt is restarted without one, and the user is told")
  func agentWithoutPrompt() async throws {
    let provider = StubProvider(capabilities: AgentCapabilities())
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
          path: "/work/app",
          git: GitSnapshot(repositoryRootPath: "/work/app", worktreePath: "/work/app-hotfix")
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

    let refusal = await restart.problem(for: id)

    #expect(refusal == .notRestartable(.archived))
    #expect(refusal?.recoverySuggestion == "Unarchive it first, then restart it.")
    #expect(await repository.writes == 0)
  }

  @Test("A running session has nothing to restart")
  func activeIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(status: .active, closedAt: nil))

    #expect(await restart.problem(for: repository.stored[0].id) == .notRestartable(.active))
    #expect(await repository.writes == 0)
  }

  @Test("An agent that is not installed any more stops the restart, with its name")
  func unknownAgentIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(providerID: "gone"))

    #expect(await restart.problem(for: repository.stored[0].id) == .agentUnknown("gone"))
    #expect(await repository.writes == 0)
  }

  @Test("An agent that cannot run right now stops the restart, with its remedy")
  func unavailableAgentIsRefused() async throws {
    let (restart, repository) = makeSubject(
      session: session(),
      provider: StubProvider(state: .notFound)
    )

    guard case .agentUnavailable = await restart.problem(for: repository.stored[0].id) else {
      Issue.record("An unusable agent must refuse the restart")
      return
    }
    #expect(await repository.writes == 0)
  }

  @Test("A folder that disappeared is caught before a terminal is ever opened")
  func missingFolderIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(), folder: .missing)

    #expect(
      await restart.problem(for: repository.stored[0].id)
        == .workingDirectoryUnusable(path: "/work/app", status: .missing)
    )
    #expect(await repository.writes == 0)
  }

  @Test("A session without a folder is refused rather than started somewhere arbitrary")
  func noFolderIsRefused() async throws {
    let (restart, repository) = makeSubject(session: session(repositories: []))

    #expect(await restart.problem(for: repository.stored[0].id) == .noRepository)
    #expect(await repository.writes == 0)
  }

  @Test("A session that is gone from the store is refused")
  func missingSessionIsRefused() async throws {
    let (restart, _) = makeSubject(session: session())

    #expect(await restart.problem(for: SessionID()) == .sessionMissing)
  }

  @Test("A launch the agent refuses is reported as such, and writes nothing")
  func launchRejectionIsReported() async throws {
    let provider = StubProvider(launchFailure: .promptTooLarge(byteCount: 40_000, limit: 16_384))
    let (restart, repository) = makeSubject(
      session: session(resumeIdentifier: nil),
      provider: provider
    )

    let refusal = await restart.problem(for: repository.stored[0].id)

    #expect(
      refusal == .launchRejected(.promptTooLarge(byteCount: 40_000, limit: 16_384))
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

private struct StubFolders: WorkingDirectoryProbe {
  let status: WorkingDirectoryStatus

  func inspect(path: String) async -> WorkingDirectoryStatus { status }
}

private struct StubProvider: AgentProvider {
  let descriptor: AgentDescriptor
  let state: AgentAvailabilityState
  let launchFailure: AgentLaunchError?
  /// Raised only when a resume is asked for, as a CLI refusing a stored identifier would.
  let resumeFailure: AgentLaunchError?

  init(
    state: AgentAvailabilityState = .available,
    capabilities: AgentCapabilities = AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    ),
    launchFailure: AgentLaunchError? = nil,
    resumeFailure: AgentLaunchError? = nil
  ) {
    descriptor = AgentDescriptor(
      id: AgentProviderID("stub"),
      displayName: "Stub Agent",
      capabilities: capabilities
    )
    self.state = state
    self.launchFailure = launchFailure
    self.resumeFailure = resumeFailure
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: state,
      installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id,
        providerName: descriptor.displayName,
        state: state,
        summary: "Stub Agent is \(state == .available ? "ready" : "unusable").",
        probedAt: Date(timeIntervalSince1970: 0),
        remediations: state == .available ? [] : [.install(documentationURL: nil)]
      )
    )
  }

  func models() async -> [AgentModel] { [] }

  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    if let launchFailure { throw launchFailure }
    if case .identifier = request.resume, let resumeFailure { throw resumeFailure }

    var arguments: [String] = []
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    if let modelID = request.modelID {
      arguments.append(contentsOf: ["--model", modelID])
    }
    return AgentLaunchPlan(
      providerID: descriptor.id,
      executablePath: "/usr/bin/true",
      arguments: arguments,
      environment: [:],
      workingDirectoryPath: request.workingDirectoryPath,
      promptDelivery: request.initialPrompt == nil ? .none : .argument
    )
  }
}

private struct StubRegistry: AgentProviderResolving {
  var providers: [StubProvider]

  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }

  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }

  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] {
    var result: [AgentProviderID: AgentAvailability] = [:]
    for provider in providers {
      result[provider.descriptor.id] = await provider.availability(forceRefresh: forceRefresh)
    }
    return result
  }
}
