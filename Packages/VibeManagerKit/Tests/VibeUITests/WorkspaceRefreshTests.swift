import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Refreshing without blanking the workspace")
struct WorkspaceRefreshTests {
  @Test("The first load is the only one that shows a spinner")
  func onlyTheFirstLoadBlanks() async {
    let existing = WorkSession(name: "Already there")
    let repository = GatedRepository(sessions: [existing])
    let model = AppModel(repository: repository)

    await repository.open()
    await model.reload()
    #expect(model.state == .loaded([existing]))

    // A second refresh, held open: what is on screen stays on screen.
    await repository.close()
    let refresh = Task { await model.reload() }
    await Task.yield()
    #expect(model.state == .loaded([existing]))

    await repository.open()
    await refresh.value
    #expect(model.state == .loaded([existing]))
  }

  @Test("A created session is listed before its terminal is started")
  func createdSessionIsListedImmediately() async {
    let existing = WorkSession(name: "Already there")
    let repository = GatedRepository(sessions: [existing])
    let model = AppModel(repository: repository)
    await repository.open()
    await model.reload()

    // The store is held closed: nothing can be read back, yet the session must still appear.
    await repository.close()
    let created = WorkSession(name: "Just created")
    await model.complete(SessionCreation(session: created, plan: plan()))

    #expect(model.sessions.map(\.name).contains("Just created"))
    #expect(model.selectedSessionID == created.id)
    #expect(model.state != .loading)
  }

  private func plan() -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: AgentProviderID("stub"),
      executablePath: "/usr/bin/true",
      arguments: [],
      environment: [:],
      workingDirectoryPath: "/workspace",
      promptDelivery: .none
    )
  }
}

/// A store that can be held closed, so a refresh stays in flight while the state is inspected.
private actor GatedRepository: SessionRepository {
  private var stored: [WorkSession]
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func open() {
    isOpen = true
    let waiters = self.waiters
    self.waiters = []
    waiters.forEach { $0.resume() }
  }

  func close() {
    isOpen = false
  }

  func sessions() async -> [WorkSession] {
    while !isOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    return stored
  }

  func session(id: SessionID) async -> WorkSession? {
    await sessions().first { $0.id == id }
  }

  func save(_ session: WorkSession) {
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}
