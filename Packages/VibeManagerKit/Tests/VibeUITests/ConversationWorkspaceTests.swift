import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The conversations kept in memory")
struct ConversationWorkspaceTests {
  private func sessions(_ count: Int) -> [WorkSession] {
    (0..<count).map { WorkSession(name: "S\($0)", status: .active) }
  }

  @Test("A session no longer mounted keeps what was read, and gets it back when shown again")
  func dormant() {
    let workspace = ConversationWorkspace()
    let listed = sessions(ConversationWorkspace.keptModelCount + 1)
    let first = workspace.show(listed[0])
    for session in listed.dropFirst() { workspace.show(session) }
    #expect(!workspace.mountedSessionIDs.contains(listed[0].id))
    #expect(workspace.existingModel(for: listed[0].id) === first)

    #expect(workspace.show(listed[0]) === first)
    #expect(workspace.mountedSessionIDs.last == listed[0].id)
    #expect(workspace.mountedSessionIDs.count == ConversationWorkspace.keptModelCount)
  }

  @Test("Past the dormant ones, the oldest conversation is let go of")
  func released() {
    let workspace = ConversationWorkspace()
    let listed = sessions(
      ConversationWorkspace.keptModelCount + ConversationWorkspace.dormantModelCount + 1)
    for session in listed { workspace.show(session) }
    #expect(workspace.existingModel(for: listed[0].id) == nil)
    #expect(workspace.existingModel(for: listed[1].id) != nil)
  }

  @Test("A dormant conversation takes the last activity when it is shown again")
  func activity() {
    let workspace = ConversationWorkspace()
    let listed = sessions(ConversationWorkspace.keptModelCount + 1)
    let first = workspace.show(listed[0])
    for session in listed.dropFirst() { workspace.show(session) }
    workspace.activityChanged(
      listed[0].id, to: AgentActivityState(activity: .working, source: .structured))
    #expect(first.activity == nil)
    workspace.show(listed[0])
    #expect(first.activity == .working)
  }
}
