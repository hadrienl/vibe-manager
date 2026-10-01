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

  @Test("Sessions stopped with the host are listed together, leave as they close, and restart")
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

    // Closing one takes it off the list; nothing restarted on its own meanwhile.
    await model.close(sessions[0].id)
    #expect(model.sessionsStoppedWithHost == [sessions[1].id])
    #expect(!launcher.isRunning(sessions[1].id))

    await model.restartSessionsStoppedWithHost()
    if let confirmation = model.pendingBatch {
      await model.confirmBatch(confirmation)
    }
    await waitUntil("the remaining one runs again") { launcher.isRunning(sessions[1].id) }
    #expect(model.sessionsStoppedWithHost.isEmpty)
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
