import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private actor FakeSessionRepository: SessionRepository {
  private let values: [WorkSession]

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() -> [WorkSession] {
    values
  }

  func session(id: SessionID) -> WorkSession? {
    values.first { $0.id == id }
  }

  func save(_: WorkSession) {}
}

@MainActor
@Test("The app model loads sessions from its injected repository")
func appModelLoadsInjectedSessions() async {
  let session = WorkSession(name: "Injected session")
  let model = AppModel(repository: FakeSessionRepository(values: [session]))

  await model.load()

  #expect(model.state == .loaded([session]))
}

private struct DamagedStoreError: LocalizedError {
  var errorDescription: String? {
    "The session store is damaged, but a backup can be restored."
  }
}

private actor RecoverableRepository: SessionRepository, SessionStoreRecovery {
  private let values: [WorkSession]
  private var isHealthy = false

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() throws -> [WorkSession] {
    guard isHealthy else { throw DamagedStoreError() }
    return values
  }

  func session(id: SessionID) throws -> WorkSession? {
    try sessions().first { $0.id == id }
  }

  func save(_: WorkSession) {}

  func recoveryStatus() -> SessionStoreRecoveryStatus {
    isHealthy ? .notNeeded : .backupAvailable
  }

  func restoreBackup() {
    isHealthy = true
  }
}

@MainActor
@Test("A store failure surfaces its description and its recovery option")
func appModelSurfacesStoreFailure() async {
  let session = WorkSession(name: "Recovered session")
  let repository = RecoverableRepository(values: [session])
  let model = AppModel(repository: repository, recovery: repository)

  await model.load()

  #expect(
    model.state
      == .failed(
        message: "The session store is damaged, but a backup can be restored.",
        canRestoreBackup: true
      )
  )

  await model.restoreBackup()

  #expect(model.state == .loaded([session]))
}
