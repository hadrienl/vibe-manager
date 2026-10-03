import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// VoiceOver offers on a session's row only the commands that would do something (#232).
@MainActor
@Suite("The actions of a session's row")
struct SessionRowActionTests {
  private func model(_ sessions: [WorkSession]) async -> AppModel {
    let model = AppModel(
      repository: WorkspaceRepository(sessions: sessions),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    return model
  }

  @Test("An archived session offers Unarchive, not Archive nor Close")
  func archived() async {
    let session = WorkSession(
      name: "Old", agent: SessionAgentConfiguration(providerID: "stub"), status: .archived)
    let model = await model([session])
    let actions = SessionCommands(model: model, session: session).rowActions
    #expect(actions.contains(.restore))
    #expect(!actions.contains(.archive))
    #expect(!actions.contains(.close))
    #expect(!actions.contains(.switchAgent))
  }

  @Test("An active session offers Close and Archive, not Unarchive")
  func active() async {
    let session = WorkSession(
      name: "Now", agent: SessionAgentConfiguration(providerID: "stub"), status: .active)
    let model = await model([session])
    let actions = SessionCommands(model: model, session: session).rowActions
    #expect(actions.contains(.close))
    #expect(actions.contains(.archive))
    #expect(!actions.contains(.restore))
  }
}
