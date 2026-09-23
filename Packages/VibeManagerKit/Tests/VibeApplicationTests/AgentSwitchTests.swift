import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Switching the agent or model of a session")
struct AgentSwitchTests {
  // MARK: - Fixtures

  private static let claude = RestorationProvider(
    id: "claude-code",
    displayName: "Claude Code",
    models: [
      AgentModel(id: "opus", displayName: "Opus"), AgentModel(id: "sonnet", displayName: "Sonnet"),
    ]
  )
  private static let codex = RestorationProvider(
    id: "codex",
    displayName: "Codex",
    models: [AgentModel(id: "gpt-5.5", displayName: "GPT-5.5")]
  )
  private static let names = ["claude-code": "Claude Code", "codex": "Codex"]

  private func session(
    status: SessionStatus = .closed,
    resumeIdentifier: String? = "8c1d0b7e-1111-4222-8333-444455556666",
    prompt: String = "Audit the dependencies.",
    notes: String? = "Keep lodash.",
    startedAt: Date? = Date(timeIntervalSince1970: 1_699_000_000)
  ) -> WorkSession {
    WorkSession(
      name: "Audit deps",
      initialPrompt: prompt,
      agent: SessionAgentConfiguration(
        providerID: "claude-code", modelID: "opus", resumeIdentifier: resumeIdentifier),
      status: status,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: status == .active ? nil : Date(timeIntervalSince1970: 1_700_000_100),
      archivedAt: status == .archived ? Date(timeIntervalSince1970: 1_700_000_100) : nil,
      startedAt: startedAt,
      repositories: [RepositoryContext(path: "/work/app")],
      notes: notes
    )
  }

  private func subject(
    _ session: WorkSession,
    providers: [RestorationProvider] = [claude, codex],
    folder: WorkingDirectoryStatus = .usable,
    journal: RestorationJournal? = nil
  ) -> (PlanAgentSwitch, RestorationRepository) {
    let repository = RestorationRepository(sessions: [session], journal: journal)
    let plan = PlanAgentSwitch(
      repository: repository,
      agents: RestorationRegistry(providers: providers),
      folders: RestorationFolders(status: folder)
    )
    return (plan, repository)
  }

  private func refusal(
    _ plan: PlanAgentSwitch,
    _ id: SessionID,
    to target: AgentTarget,
    summary: String? = nil
  ) async -> AgentSwitchRefusal? {
    do {
      _ = try await plan(id: id, to: target, summaryOverride: summary)
      return nil
    } catch let refusal as AgentSwitchRefusal {
      return refusal
    } catch {
      Issue.record("Unexpected error \(error)")
      return nil
    }
  }

  // MARK: - Modes

  @Test("Another model of the same agent resumes its conversation, and sends no text")
  func sameAgentResumesWithTheNewModel() async throws {
    let stored = session()
    let (plan, _) = subject(stored)

    let planned = try await plan(
      id: stored.id, to: AgentTarget(providerID: "claude-code", modelID: "sonnet"))

    #expect(planned.mode == .resumeWithModel(identifier: "8c1d0b7e-1111-4222-8333-444455556666"))
    #expect(
      planned.plan.arguments == [
        "--resume", "8c1d0b7e-1111-4222-8333-444455556666", "--model", "sonnet",
      ])
    #expect(planned.plan.promptDelivery == .none)
    #expect(planned.nextConfiguration.resumeIdentifier == "8c1d0b7e-1111-4222-8333-444455556666")
  }

  @Test("Another model without a conversation to resume is a handover")
  func sameAgentWithoutIdentifierHandsOver() async throws {
    let stored = session(resumeIdentifier: nil)
    let (plan, _) = subject(stored)

    let planned = try await plan(
      id: stored.id, to: AgentTarget(providerID: "claude-code", modelID: "sonnet"))

    let brief = try #require(planned.mode.brief)
    #expect(brief.text.contains("an earlier conversation"))
    #expect(planned.nextConfiguration.resumeIdentifier == nil)
  }

  @Test("Another agent is handed a summary naming the one before it, and never its identifier")
  func anotherAgentIsHandedASummary() async throws {
    let stored = session()
    let (plan, _) = subject(stored)

    let planned = try await plan(
      id: stored.id,
      to: AgentTarget(providerID: "codex", modelID: "gpt-5.5"),
      context: SessionBriefInput(session: stored, agentNames: Self.names)
    )

    let brief = try #require(planned.mode.brief)
    #expect(brief.text.contains("another coding agent"))
    #expect(brief.text.contains("Claude Code · opus, from"))
    #expect(brief.text.contains("Audit the dependencies."))
    #expect(brief.text.contains("Keep lodash."))
    #expect(!brief.text.contains("8c1d0b7e"))
    #expect(planned.plan.arguments.last == brief.text)
    #expect(planned.targetName == "Codex")
    #expect(
      planned.nextConfiguration
        == SessionAgentConfiguration(providerID: "codex", modelID: "gpt-5.5"))
  }

  @Test("An emptied summary tells the new agent nothing")
  func emptiedSummaryStartsFresh() async throws {
    let stored = session()
    let (plan, _) = subject(stored)

    let planned = try await plan(
      id: stored.id, to: AgentTarget(providerID: "codex"), summaryOverride: "  \n")

    #expect(planned.mode == .freshWithoutContext)
    #expect(planned.plan.promptDelivery == .none)
  }

  @Test("A session that never ran gets the launch it never had, initial prompt included")
  func neverStartedGetsItsFirstLaunch() async throws {
    // Built from a draft, as `CreateSession` stores it: a hand-made "never started" closed session
    // would be read as having run.
    let stored = SessionDraft(
      name: "Audit deps",
      initialPrompt: "Audit the dependencies.",
      providerID: "claude-code",
      modelID: "opus",
      workingDirectoryPath: "/work/app"
    )
    .session(createdAt: Date(timeIntervalSince1970: 1_699_000_000))
    let (plan, _) = subject(stored)

    let planned = try await plan(id: stored.id, to: AgentTarget(providerID: "codex"))

    #expect(planned.mode == .firstLaunch)
    #expect(planned.plan.arguments.last == "Audit the dependencies.")
  }

  @Test("A running session can be planned: nothing is stopped to find out")
  func runningSessionIsPlanned() async throws {
    let stored = session(status: .active)
    let journal = RestorationJournal()
    let (plan, repository) = subject(stored, journal: journal)

    _ = try await plan(id: stored.id, to: AgentTarget(providerID: "codex"))

    #expect(await repository.session(id: stored.id) == stored)
    #expect(await journal.entries.isEmpty)
  }

  @Test("An agent that is not installed any more does not keep its session from switching")
  func unavailableCurrentAgentDoesNotBlock() async throws {
    let stored = session()
    let (plan, _) = subject(stored, providers: [Self.codex])

    let planned = try await plan(id: stored.id, to: AgentTarget(providerID: "codex"))

    #expect(planned.mode.brief != nil)
  }

  // MARK: - Refusals

  @Test("Every refusal is decided before anything is written")
  func refusalsWriteNothing() async throws {
    let stored = session()
    let journal = RestorationJournal()
    let unavailable = RestorationProvider(id: "codex", displayName: "Codex", state: .notFound)
    let (plan, repository) = subject(
      stored, providers: [Self.claude, unavailable], journal: journal)

    #expect(
      await refusal(plan, stored.id, to: AgentTarget(providerID: "claude-code", modelID: "opus"))
        == .nothingToChange)
    #expect(
      await refusal(plan, stored.id, to: AgentTarget(providerID: "gemini"))
        == .targetUnknown("gemini"))
    if case .targetUnavailable(let name, _, _)? = await refusal(
      plan, stored.id, to: AgentTarget(providerID: "codex"))
    {
      #expect(name == "Codex")
    } else {
      Issue.record("An unusable target must be refused")
    }
    #expect(
      await refusal(plan, stored.id, to: AgentTarget(providerID: "claude-code", modelID: "haiku"))
        == .modelUnknown(model: "haiku", agentName: "Claude Code"))
    #expect(await repository.session(id: stored.id) == stored)
    #expect(await journal.entries.isEmpty)
  }

  @Test("An archived session, or a folder that is gone, is refused")
  func archivedAndMissingFolderAreRefused() async throws {
    let archived = session(status: .archived)
    let (plan, _) = subject(archived)
    #expect(
      await refusal(plan, archived.id, to: AgentTarget(providerID: "codex"))
        == .notSwitchable(.archived))

    let stored = session()
    let (gone, _) = subject(stored, folder: .missing)
    #expect(
      await refusal(gone, stored.id, to: AgentTarget(providerID: "codex"))
        == .workingDirectoryUnusable(path: "/work/app", status: .missing))
  }

  @Test("A summary over the limit is refused with its excess, never cut")
  func summaryOverTheLimitIsRefused() async throws {
    let stored = session()
    let (plan, _) = subject(stored)
    let text = String(repeating: "a", count: AgentPromptLimits.argumentByteLimit + 1_000)

    #expect(
      await refusal(plan, stored.id, to: AgentTarget(providerID: "codex"), summary: text)
        == .summaryTooLong(overBy: 1_000))
  }

  // MARK: - Writing it

  @Test("Recording writes the agent and its history, then undoing puts everything back")
  func recordThenRevert() async throws {
    let stored = session()
    let (plan, repository) = subject(stored)
    let planned = try await plan(id: stored.id, to: AgentTarget(providerID: "codex"))

    let change = try await RecordAgentSwitch(
      repository: repository, clock: RestorationClock(Date(timeIntervalSince1970: 1_700_000_200))
    )(planned, wasEdited: true)

    let switched = try #require(await repository.session(id: stored.id))
    #expect(switched.agent == SessionAgentConfiguration(providerID: "codex"))
    #expect(switched.agentHistory == [change])
    if case .summary(_, _, let wasEdited) = change.handover {
      #expect(wasEdited)
    } else {
      Issue.record("A handover records its summary")
    }
    #expect(switched.notes == stored.notes)
    #expect(switched.lifecycle == stored.lifecycle)

    try await RevertAgentSwitch(repository: repository)(
      id: stored.id, change: change.id, reason: "Codex could not be started.")

    let reverted = try #require(await repository.session(id: stored.id))
    #expect(reverted.agent == stored.agent)
    #expect(reverted.agentHistory.first?.outcome == .failed(reason: "Codex could not be started."))
  }

  @Test("A session archived while its agent was stopped is not handed to anyone")
  func archivedDuringTheStopIsNotSwitched() async throws {
    let stored = session()
    let (plan, repository) = subject(stored)
    let planned = try await plan(id: stored.id, to: AgentTarget(providerID: "codex"))
    _ = try await repository.mutate(id: stored.id) {
      try $0.archive(at: Date(timeIntervalSince1970: 1_700_000_200))
    }

    await #expect(throws: AgentSwitchRefusal.sessionMoved) {
      try await RecordAgentSwitch(repository: repository)(planned, wasEdited: false)
    }
    #expect(await repository.session(id: stored.id)?.agentHistory.isEmpty == true)
  }
}

@Suite("Summarising a session for the agent it is handed to")
struct HandoverBriefTests {
  private let readAt = Date(timeIntervalSince1970: 1_700_000_300)

  private func session(prompt: String = "Audit the dependencies.") throws -> WorkSession {
    var session = WorkSession(
      name: "Audit deps",
      initialPrompt: prompt,
      agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: Date(timeIntervalSince1970: 1_700_000_100),
      startedAt: Date(timeIntervalSince1970: 1_699_000_000),
      repositories: [RepositoryContext(path: "/work/app")],
      notes: "Keep lodash."
    )
    try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "codex"),
      handover: .nothing,
      at: Date(timeIntervalSince1970: 1_699_500_000)
    )
    try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"),
      handover: .nothing,
      at: Date(timeIntervalSince1970: 1_699_800_000)
    )
    return session
  }

  private func report() -> SessionBranchReport {
    SessionBranchReport(
      sessionID: SessionID(),
      repositories: [
        RepositoryBranchReport(
          path: "/work/app/.claude/worktrees/audit",
          name: "app · worktree audit",
          involvement: .edited,
          checkedOutBranch: "feat/audit",
          change: BranchChange(name: "feat/audit", kind: .created, commitCount: 3),
          isDirty: true
        ),
        RepositoryBranchReport(
          path: "/work/docs",
          name: "docs",
          involvement: .attached,
          checkedOutBranch: "main",
          change: nil,
          isDirty: false
        ),
      ],
      visitedOnly: ["prisme.ai"],
      readAt: readAt
    )
  }

  private func input(_ session: WorkSession, branches: SessionBranchReport? = nil)
    -> SessionBriefInput
  {
    SessionBriefInput(
      session: session,
      branches: branches,
      agentNames: ["claude-code": "Claude Code", "codex": "Codex"]
    )
  }

  @Test("Where the work is comes from the branch report, with the order to stay on it")
  func whereTheWorkIs() throws {
    let brief = SessionContextBriefBuilder().handover(
      input(try session(), branches: report()),
      to: SessionAgentConfiguration(providerID: "codex"))

    #expect(brief.text.contains("Where the work is, read "))
    #expect(
      brief.text.contains(
        "- app · worktree audit — /work/app/.claude/worktrees/audit, branch feat/audit (created in this session, 3 commits since), with uncommitted changes"
      ))
    #expect(brief.text.contains("- docs — /work/docs, branch main, clean"))
    #expect(brief.text.contains("Also looked in: prisme.ai"))
    #expect(brief.text.contains("Do not create new branches or worktrees unless asked."))
    #expect(brief.fits)
  }

  @Test("Without a report, the recorded folders are said, as recorded")
  func withoutAReportFallsBackToTheSnapshots() throws {
    let brief = SessionContextBriefBuilder().handover(
      input(try session()), to: SessionAgentConfiguration(providerID: "codex"))

    #expect(brief.includedSections.contains(.folders))
    #expect(brief.text.contains("- /work/app"))
  }

  @Test("Every agent that ran is listed, in order, the current one until this handover")
  func agentsSoFar() throws {
    let brief = SessionContextBriefBuilder().handover(
      input(try session()), to: SessionAgentConfiguration(providerID: "codex"))

    let lines = brief.text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
    #expect(lines.count == 4)
    #expect(lines[0].hasPrefix("- Claude Code · sonnet, from "))
    #expect(lines[1].hasPrefix("- Codex, from "))
    #expect(lines[2].hasSuffix("until this handover"))
  }

  @Test("Shortening gives up history, notes, then details, and never the initial prompt")
  func shorteningKeepsThePrompt() throws {
    let prompt = String(repeating: "p", count: 15_400)
    let brief = SessionContextBriefBuilder().handover(
      input(try session(prompt: prompt), branches: report()),
      to: SessionAgentConfiguration(providerID: "codex"))

    #expect(brief.isTruncated)
    #expect(brief.text.contains(prompt))
    #expect(!brief.includedSections.contains(.notes))
    #expect(!brief.includedSections.contains(.visited))
    #expect(brief.fits)
  }

  @Test("A prompt the rest cannot make room for is reported over the limit, not cut")
  func overflowIsReported() throws {
    let prompt = String(repeating: "p", count: AgentPromptLimits.argumentByteLimit)
    let brief = SessionContextBriefBuilder().handover(
      input(try session(prompt: prompt)), to: SessionAgentConfiguration(providerID: "codex"))

    #expect(!brief.fits)
    #expect(brief.text.contains(prompt))
    #expect(brief.overflowByteCount == brief.text.utf8.count - AgentPromptLimits.argumentByteLimit)
  }

  @Test("The restart summary of a switched session says another agent worked here")
  func restartSummaryNamesThePreviousAgents() throws {
    let brief = SessionContextBriefBuilder()(for: try session())

    #expect(
      brief.text.contains("Agent: claude-code · sonnet (previously claude-code · sonnet, codex)"))
  }
}
