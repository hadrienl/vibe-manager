import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
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

  @Test("Readings are put aside for as many sessions as models sleep (#249)")
  func parkedAsManyAsDormant() {
    #expect(FollowConversation.parkedLimit == ConversationWorkspace.dormantModelCount)
  }

  @Test("A request for the composer made before its model exists is handed to it (#105)")
  func pendingFocus() {
    let workspace = ConversationWorkspace()
    let listed = sessions(2)
    #expect(workspace.requestComposerFocus(for: listed[0].id))
    #expect(workspace.existingModel(for: listed[0].id) == nil)
    let other = workspace.show(listed[1])
    #expect(other.focusComposerRequest == 0)
    let model = workspace.show(listed[0])
    #expect(model.focusComposerRequest == 1)
    #expect(model.takePendingFocusRequest())
    // Handed over once: shown again, it asks for nothing.
    workspace.show(listed[0])
    #expect(model.focusComposerRequest == 1)
  }

  @Test("A request still waiting is dropped once the user is elsewhere, or the session gone")
  func pendingFocusDropped() {
    let workspace = ConversationWorkspace()
    let listed = sessions(2)
    workspace.requestComposerFocus(for: listed[0].id)
    workspace.cancelPendingComposerFocus(unless: listed[1].id)
    #expect(workspace.show(listed[0]).focusComposerRequest == 0)

    workspace.requestComposerFocus(for: listed[1].id)
    workspace.release(listed[1].id)
    #expect(workspace.show(listed[1]).focusComposerRequest == 0)
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
