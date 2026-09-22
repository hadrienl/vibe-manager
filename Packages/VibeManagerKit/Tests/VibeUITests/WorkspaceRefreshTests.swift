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

  @Test("A refresh that fails over a listed workspace keeps it, and says so in a banner")
  func failedRefreshKeepsTheWorkspace() async {
    let existing = WorkSession(name: "Already there")
    let repository = FailingRepository(sessions: [existing])
    let model = AppModel(repository: repository)
    await model.reload()
    #expect(model.state == .loaded([existing]))

    await repository.startFailing()
    await model.reload()

    #expect(model.state == .loaded([existing]))
    #expect(model.refreshFailure?.message.isEmpty == false)

    model.dismissRefreshFailure()
    #expect(model.refreshFailure == nil)
  }

  @Test("A first load that fails is the whole screen: there is nothing else to show")
  func failedFirstLoadIsTheScreen() async {
    let repository = FailingRepository(sessions: [])
    await repository.startFailing()
    let model = AppModel(repository: repository)

    await model.reload()

    #expect(model.refreshFailure == nil)
    guard case .failed = model.state else {
      Issue.record("expected a failed state, got \(model.state)")
      return
    }
  }

  @Test("A refresh that succeeds again clears the banner")
  func recoveredRefreshClearsTheBanner() async {
    let existing = WorkSession(name: "Already there")
    let repository = FailingRepository(sessions: [existing])
    let model = AppModel(repository: repository)
    await model.reload()
    await repository.startFailing()
    await model.reload()
    #expect(model.refreshFailure != nil)

    await repository.stopFailing()
    await model.reload()

    #expect(model.refreshFailure == nil)
    #expect(model.state == .loaded([existing]))
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

/// A store that can be made to refuse reads, to fail a refresh on demand.
private actor FailingRepository: SessionRepository {
  private var stored: [WorkSession]
  private var isFailing = false

  init(sessions: [WorkSession]) {
    stored = sessions
  }

  func startFailing() { isFailing = true }
  func stopFailing() { isFailing = false }

  func sessions() throws -> [WorkSession] {
    if isFailing { throw StoreUnavailable() }
    return stored
  }

  func session(id: SessionID) throws -> WorkSession? {
    try sessions().first { $0.id == id }
  }

  func save(_ session: WorkSession) throws {
    if isFailing { throw StoreUnavailable() }
    if let index = stored.firstIndex(where: { $0.id == session.id }) {
      stored[index] = session
    } else {
      stored.append(session)
    }
  }
}

private struct StoreUnavailable: Error, LocalizedError {
  var errorDescription: String? { "The session store could not be read." }
}
