import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The terminal host stopped: one message for every session it took down (#237)")
struct HostStoppedTests {
  private let path: String = {
    let path = NSTemporaryDirectory().appending("vibe-host-stopped-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }()

  private func session(_ name: String, updatedAt seconds: TimeInterval) -> WorkSession {
    let date = Date(timeIntervalSince1970: seconds)
    return WorkSession(
      name: name,
      initialPrompt: "Do \(name)",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept-\(name)"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: date,
      closedAt: date,
      startedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)],
      taskStatus: .doing
    )
  }

  @Test("Sessions stopped with the host are listed together, and restart together")
  func stoppedWithTheHost() async throws {
    let sessions = (1...3).map { session("S\($0)", updatedAt: TimeInterval(400 - $0)) }
    let repository = HostRepository(sessions: sessions)
    let supervisor = WorkspaceSupervisor()
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.load()
    await model.refreshResolutions()

    await model.requestBatch(model.batchPlan(.restart, for: sessions.map(\.id)))
    await model.confirmBatch(try #require(model.pendingBatch))
    for session in sessions { #expect(launcher.isRunning(session.id)) }
    #expect(model.sessionsStoppedWithHost.isEmpty)

    // The host goes away under two of them; the third ends on its own, for its own reasons.
    await supervisor.finish(id: sessions[0].id, state: .failed(.hostStopped))
    await supervisor.finish(id: sessions[1].id, state: .failed(.hostStopped))
    await supervisor.finish(id: sessions[2].id, state: .exited(code: 1))
    await waitUntil("the two sessions are listed as stopped with the host") {
      Set(model.sessionsStoppedWithHost) == [sessions[0].id, sessions[1].id]
    }

    // Nothing restarts on its own: each agent exited, and the session is closed as usual.
    #expect(!launcher.isRunning(sessions[0].id))
    #expect(!launcher.isRunning(sessions[1].id))
    // Their exits are recorded first, as they would be long before anyone reads the banner.
    await waitUntil("both are stored closed") {
      let first = await repository.session(id: sessions[0].id)?.status
      let second = await repository.session(id: sessions[1].id)?.status
      return first == .closed && second == .closed
    }
    await model.reload()

    // A host that stops is no agent refusing its conversation: each is resumed, not summarized.
    #expect(!model.resumeRefusals.contains(sessions[0].id))
    await model.restartSessionsStoppedWithHost()
    if let confirmation = model.pendingBatch {
      await model.confirmBatch(confirmation)
    }
    await waitUntil("both run again") {
      launcher.isRunning(sessions[0].id) && launcher.isRunning(sessions[1].id)
    }
    #expect(model.sessionsStoppedWithHost.isEmpty)
    #expect(!launcher.isRunning(sessions[2].id))
  }

  @Test("Dismissing the message sets its sessions aside, and restarts nothing")
  func dismissed() async throws {
    let stopped = session("S1", updatedAt: 300)
    let repository = HostRepository(sessions: [stopped])
    let supervisor = WorkspaceSupervisor()
    let registry = WorkspaceRegistry(providers: [WorkspaceProvider()])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.load()
    await model.refreshResolutions()
    await model.requestBatch(model.batchPlan(.restart, for: [stopped.id]))
    if let confirmation = model.pendingBatch {
      await model.confirmBatch(confirmation)
    }
    await waitUntil("it runs") { launcher.isRunning(stopped.id) }

    await supervisor.finish(id: stopped.id, state: .failed(.hostStopped))
    await waitUntil("it is listed") { model.sessionsStoppedWithHost == [stopped.id] }

    model.setAsideSessionsStoppedWithHost()

    #expect(model.sessionsStoppedWithHost.isEmpty)
    #expect(!launcher.isRunning(stopped.id))
  }
}

private actor HostRepository: SessionRepository {
  private var stored: [WorkSession]

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func sessions() -> [WorkSession] { stored }

  func session(id: SessionID) -> WorkSession? {
    stored.first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}
