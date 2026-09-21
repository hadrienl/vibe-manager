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
