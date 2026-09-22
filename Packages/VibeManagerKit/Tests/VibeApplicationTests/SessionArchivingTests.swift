import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Records what the interface was asked to let go of, and in which order relative to the store.
private actor SpyRuntime: SessionRuntime {
  private(set) var detached: [SessionID] = []
  private(set) var disposed: [SessionID] = []
  private let outcome: SessionDetachOutcome
  private let log: EventLog?

  init(outcome: SessionDetachOutcome = .stopped, log: EventLog? = nil) {
    self.outcome = outcome
    self.log = log
  }

  func detach(_ id: SessionID) async -> SessionDetachOutcome {
    detached.append(id)
    await log?.record("detach")
    return outcome
  }

  func dispose(_ id: SessionID) async {
    disposed.append(id)
    await log?.record("dispose")
  }
}

/// One ordered trace shared by the runtime and the repository, so "stopped before written" is
/// asserted on facts rather than on the shape of the code.
private actor EventLog {
  private(set) var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }
}

private actor LoggingRepository: SessionRepository {
  private var stored: [WorkSession]
  private let log: EventLog?

  init(sessions: [WorkSession], log: EventLog? = nil) {
    stored = sessions
    self.log = log
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) async {
    await log?.record("save:\(session.status.rawValue)")
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private func runningSession(name: String = "Refactor the webhook") -> WorkSession {
  WorkSession(
    name: name,
    initialPrompt: "Make the retries idempotent",
    agent: SessionAgentConfiguration(
      providerID: "claude-code",
      modelID: "opus",
      resumeIdentifier: "abc-123"
    ),
    status: .active,
    createdAt: Date(timeIntervalSince1970: 100),
    updatedAt: Date(timeIntervalSince1970: 100),
    repositories: [
      RepositoryContext(
        path: "/work/api",
        git: GitSnapshot(
          repositoryRootPath: "/work/api",
          branchName: "main",
          headRevision: "cafe1234",
          isDirty: true,
          capturedAt: Date(timeIntervalSince1970: 120)
        )
      )
    ],
    notes: "The webhook retries three times, then gives up.",
    template: PromptTemplateReference(id: "tpl-1", name: "Bug fix", revision: "3")
  )
}

@Suite("Closing a session")
struct CloseSessionTests {
  @Test("The process is stopped before the closed status is written")
  func stopsBeforeWriting() async throws {
    let log = EventLog()
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session], log: log)
    let runtime = SpyRuntime(log: log)
    let close = CloseSession(repository: repository, runtime: runtime)

    let closure = try await close(id: session.id)

    #expect(closure.session.status == .closed)
    #expect(await log.events == ["detach", "save:closed"])
    #expect(await runtime.detached == [session.id])
  }

  @Test("Closing keeps the pane: nothing is disposed")
  func closingNeverDisposes() async throws {
    let session = runningSession()
    let runtime = SpyRuntime()
    let close = CloseSession(
      repository: LoggingRepository(sessions: [session]),
      runtime: runtime
    )

    _ = try await close(id: session.id)

    #expect(await runtime.disposed.isEmpty)
  }

  @Test("Closing a session that is already closed still detaches and does not fail")
  func closingIsIdempotent() async throws {
    var session = runningSession()
    try session.close(at: Date(timeIntervalSince1970: 200))
    let runtime = SpyRuntime(outcome: .wasNotRunning)
    let close = CloseSession(
      repository: LoggingRepository(sessions: [session]),
      runtime: runtime
    )

    let closure = try await close(id: session.id)

    #expect(closure.session.status == .closed)
    #expect(closure.detachment == .wasNotRunning)
    #expect(await runtime.detached == [session.id])
  }

  @Test("An unknown session is reported rather than silently ignored")
  func unknownSessionThrows() async {
    let close = CloseSession(repository: LoggingRepository(sessions: []))

    await #expect(throws: ChangeSessionStatusError.self) {
      _ = try await close(id: SessionID())
    }
  }
}

@Suite("Archiving a session")
struct ArchiveSessionTests {
  @Test("A running session is stopped, closed and only then archived")
  func archivingGoesThroughClosing() async throws {
    let log = EventLog()
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session], log: log)
    let runtime = SpyRuntime(log: log)
    let archive = ArchiveSession(repository: repository, runtime: runtime)

    let archival = try await archive(id: session.id)

    #expect(archival.session.status == .archived)
    #expect(await log.events == ["detach", "save:closed", "save:archived", "dispose"])
    // The store keeps a real closing date, not one invented by the archive.
    #expect(archival.session.closedAt != nil)
    #expect(archival.session.archivedAt != nil)
    #expect(archival.session.closedAt! <= archival.session.archivedAt!)
  }

  @Test("The pane is released only once the store agrees the session is archived")
  func disposalComesLast() async throws {
    let session = runningSession()
    let runtime = SpyRuntime()
    let archive = ArchiveSession(
      repository: LoggingRepository(sessions: [session]),
      runtime: runtime
    )

    _ = try await archive(id: session.id)

    #expect(await runtime.disposed == [session.id])
  }

  @Test("A process that could not be stopped is reported, and the archive still happens")
  func unreachableProcessIsReported() async throws {
    let session = runningSession()
    let archive = ArchiveSession(
      repository: LoggingRepository(sessions: [session]),
      runtime: SpyRuntime(outcome: .unreachable(processIdentifier: 4242))
    )

    let archival = try await archive(id: session.id)

    #expect(archival.session.status == .archived)
    #expect(archival.detachment == .unreachable(processIdentifier: 4242))
    #expect(archival.detachment.isUnreachable)
  }

  @Test("Archiving twice changes nothing the second time")
  func archivingIsIdempotent() async throws {
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session])
    let archive = ArchiveSession(repository: repository, runtime: SpyRuntime())

    let first = try await archive(id: session.id)
    let second = try await archive(id: session.id)

    #expect(first.session == second.session)
    #expect(second.session.status == .archived)
  }

  @Test("Archiving writes nothing but the lifecycle")
  func archivingKeepsEverythingElse() async throws {
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session])
    let archive = ArchiveSession(repository: repository, runtime: SpyRuntime())
    let restore = RestoreSession(repository: repository)

    _ = try await archive(id: session.id)
    let restored = try await restore(id: session.id)

    #expect(restored.status == .closed)
    #expect(restored.name == session.name)
    #expect(restored.initialPrompt == session.initialPrompt)
    #expect(restored.notes == session.notes)
    #expect(restored.appearance == session.appearance)
    #expect(restored.agent == session.agent)
    #expect(restored.agent?.resumeIdentifier == "abc-123")
    #expect(restored.repositories == session.repositories)
    #expect(restored.repositories.first?.git == session.repositories.first?.git)
    #expect(restored.template == session.template)
    #expect(restored.createdAt == session.createdAt)
  }
}

@Suite("Unarchiving a session")
struct RestoreSessionTests {
  @Test("An archived session comes back closed, and nothing is started")
  func restoreReturnsToClosed() async throws {
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session])
    let runtime = SpyRuntime()
    _ = try await ArchiveSession(repository: repository, runtime: runtime)(id: session.id)

    let restored = try await RestoreSession(repository: repository)(id: session.id)

    #expect(restored.status == .closed)
    #expect(restored.archivedAt == nil)
    // The session was closed before it was archived, and unarchiving does not forget when.
    #expect(restored.closedAt != nil)
  }

  @Test("Unarchiving a session that is not archived leaves it alone")
  func restoreIsIdempotent() async throws {
    let session = runningSession()
    let repository = LoggingRepository(sessions: [session])

    let unchanged = try await RestoreSession(repository: repository)(id: session.id)

    #expect(unchanged.status == .active)
  }
}
