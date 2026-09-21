import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

private actor ClaudeCaptureRepository: SessionRepository {
  private var stored: WorkSession
  private(set) var saveCount = 0

  init(stored: WorkSession) {
    self.stored = stored
  }

  func sessions() -> [WorkSession] {
    [stored]
  }

  func session(id: SessionID) -> WorkSession? {
    stored.id == id ? stored : nil
  }

  func save(_ session: WorkSession) {
    stored = session
    saveCount += 1
  }
}

/// A session that only appears after a few attempts, the way a pane can start before the row
/// it belongs to has been written.
private actor LateRepository: SessionRepository {
  private var stored: WorkSession?
  private let appearsAfter: Int
  private var reads = 0

  init(session: WorkSession, appearsAfter: Int) {
    self.appearsAfter = appearsAfter
    pending = session
  }

  private var pending: WorkSession

  func sessions() -> [WorkSession] {
    stored.map { [$0] } ?? []
  }

  func session(id: SessionID) -> WorkSession? {
    reads += 1
    if reads > appearsAfter, stored == nil {
      stored = pending
    }
    return stored?.id == id ? stored : nil
  }

  func save(_ session: WorkSession) {
    stored = session
  }
}

private actor NeverRepository: SessionRepository {
  func sessions() -> [WorkSession] { [] }
  func session(id: SessionID) -> WorkSession? { nil }
  func save(_ session: WorkSession) {}
}

private func claudeSession() -> WorkSession {
  WorkSession(
    name: "Refonte du parseur",
    agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "claude-opus-5")
  )
}

private func plan(arguments: [String]) -> AgentLaunchPlan {
  AgentLaunchPlan(
    providerID: ClaudeCodeAgentProvider.id,
    executablePath: "/opt/homebrew/bin/claude",
    arguments: arguments,
    environment: [:],
    workingDirectoryPath: "/Users/test/app",
    promptDelivery: .none
  )
}

@Suite("Claude Code session identifier capture")
struct ClaudeCodeSessionIdentifierCaptureTests {
  private let identifier = "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04"

  @Test("The identifier the plan assigned is stored on the session")
  func storesAssignedIdentifier() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository)
    )

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    #expect(await capture.identifier == identifier)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A resume plan changes nothing: the identifier is already stored")
  func resumePlanIsInert() async throws {
    var session = claudeSession()
    session.agent?.resumeIdentifier = identifier
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository)
    )

    let recorded = await capture.record(plan: plan(arguments: ["--resume", identifier]))

    #expect(recorded == nil)
    #expect(await repository.saveCount == 0)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("A new launch of the same session replaces the previous conversation")
  func replacesOnRelaunch() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository)
    )
    let second = "8c1d0b7e-1111-4222-8333-444455556666"

    await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    await capture.record(plan: plan(arguments: ["--session-id", second]))

    #expect(await capture.identifier == second)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == second)
  }

  @Test("A plan without an assigned identifier writes nothing")
  func ignoresPlansWithoutIdentifier() async throws {
    let session = claudeSession()
    let repository = ClaudeCaptureRepository(stored: session)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository)
    )

    await capture.record(plan: plan(arguments: ["--model", "claude-opus-5"]))

    #expect(await capture.identifier == nil)
    #expect(await repository.saveCount == 0)
  }

  @Test("A session that is not written yet is waited for, not given up on")
  func retriesUntilTheSessionExists() async {
    let session = claudeSession()
    let repository = LateRepository(session: session, appearsAfter: 2)
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: repository),
      persistenceWindow: .seconds(5)
    )

    let assigned = await capture.record(plan: plan(arguments: ["--session-id", identifier]))
    #expect(assigned == identifier)

    #expect(await capture.settled() == identifier)
    #expect(await capture.unstoredIdentifier == nil)
    #expect(await repository.session(id: session.id)?.agent?.resumeIdentifier == identifier)
  }

  @Test("An identifier that could never be stored is surfaced, not dropped")
  func reportsUnstoredIdentifier() async {
    let session = claudeSession()
    let capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: session.id,
      record: RecordAgentResumeIdentifier(repository: NeverRepository()),
      persistenceWindow: .milliseconds(400)
    )

    let assigned = await capture.record(plan: plan(arguments: ["--session-id", identifier]))

    #expect(assigned == identifier)
    #expect(await capture.settled() == nil)
    // The conversation exists on disk; saying nothing would lose it silently.
    #expect(await capture.unstoredIdentifier == identifier)
    #expect(await capture.assignedIdentifier == identifier)
  }
}
