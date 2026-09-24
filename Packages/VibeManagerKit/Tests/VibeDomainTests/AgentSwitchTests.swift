import Foundation
import Testing

@testable import VibeDomain

private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

private func workedSession(status: SessionStatus = .closed) -> WorkSession {
  WorkSession(
    name: "Audit deps",
    initialPrompt: "Audit the dependencies.",
    agent: SessionAgentConfiguration(
      providerID: "claude-code", modelID: "opus", resumeIdentifier: "claude-1"),
    appearance: SessionAppearance(symbolName: "leaf", colorHex: "#30D158"),
    status: status,
    createdAt: createdAt,
    updatedAt: createdAt.addingTimeInterval(60),
    closedAt: status == .active ? nil : createdAt.addingTimeInterval(60),
    archivedAt: status == .archived ? createdAt.addingTimeInterval(60) : nil,
    startedAt: createdAt,
    repositories: [RepositoryContext(path: "/tmp/audit")],
    legacyNotes: "Keep lodash."
  )
}

@Test("Switching keeps the agent it leaves, and nothing else moves")
func switchingRecordsThePreviousAgent() throws {
  var session = workedSession()
  let before = session
  let next = SessionAgentConfiguration(providerID: "codex", modelID: "gpt-5.5")

  let change = try session.switchAgent(
    to: next,
    handover: .summary(byteCount: 1_200, isTruncated: false, wasEdited: false),
    at: createdAt.addingTimeInterval(120)
  )

  #expect(session.agent == next)
  #expect(session.agentHistory == [change])
  #expect(change.previous == before.agent)
  #expect(change.outcome == .completed)
  #expect(change.changesProvider)
  // A switch writes the agent and its history, and nothing the user wrote.
  #expect(session.name == before.name)
  #expect(session.initialPrompt == before.initialPrompt)
  #expect(session.legacyNotes == before.legacyNotes)
  #expect(session.appearance == before.appearance)
  #expect(session.repositories == before.repositories)
  #expect(session.lifecycle == before.lifecycle)
  #expect(session.template == before.template)
}

@Test("Only a stopped session with an agent, moving somewhere else, can switch")
func switchingIsRefusedWhenItCannotHold() throws {
  let next = SessionAgentConfiguration(providerID: "codex")

  var running = workedSession(status: .active)
  #expect(throws: AgentSwitchError.notClosed(.active)) {
    try running.switchAgent(to: next, handover: .nothing, at: createdAt)
  }
  var archived = workedSession(status: .archived)
  #expect(throws: AgentSwitchError.notClosed(.archived)) {
    try archived.switchAgent(to: next, handover: .nothing, at: createdAt)
  }
  var agentless = WorkSession(name: "No agent", createdAt: createdAt, updatedAt: createdAt)
  #expect(throws: AgentSwitchError.noAgent) {
    try agentless.switchAgent(to: next, handover: .nothing, at: createdAt)
  }
  var same = workedSession()
  #expect(throws: AgentSwitchError.nothingToChange) {
    try same.switchAgent(
      to: SessionAgentConfiguration(providerID: "claude-code", modelID: "opus"),
      handover: .nothing,
      at: createdAt
    )
  }
  #expect(same.agentHistory.isEmpty)
}

@Test("Undoing the last switch restores the previous agent, resume identifier included")
func revertRestoresThePreviousAgent() throws {
  var session = workedSession()
  let previous = session.agent
  let change = try session.switchAgent(
    to: SessionAgentConfiguration(providerID: "codex"),
    handover: .nothing,
    at: createdAt.addingTimeInterval(120)
  )

  try session.revertAgentSwitch(change.id, reason: "Codex is not signed in.")

  #expect(session.agent == previous)
  #expect(session.agentHistory.count == 1)
  #expect(session.agentHistory[0].outcome == .failed(reason: "Codex is not signed in."))
  #expect(throws: AgentSwitchError.notRevertible) {
    try session.revertAgentSwitch(change.id, reason: "twice")
  }
}

@Test("Only the last switch can be undone")
func revertOnlyAppliesToTheLastSwitch() throws {
  var session = workedSession()
  let first = try session.switchAgent(
    to: SessionAgentConfiguration(providerID: "codex"),
    handover: .nothing,
    at: createdAt.addingTimeInterval(120)
  )
  try session.switchAgent(
    to: SessionAgentConfiguration(providerID: "codex", modelID: "gpt-5.5"),
    handover: .resumedConversation,
    at: createdAt.addingTimeInterval(180)
  )

  #expect(throws: AgentSwitchError.notRevertible) {
    try session.revertAgentSwitch(first.id, reason: "late")
  }
}

@Test("Conversations list every agent that was given an identifier, oldest first")
func conversationsFollowTheHistory() throws {
  var session = workedSession()
  try session.switchAgent(
    to: SessionAgentConfiguration(providerID: "codex", modelID: "gpt-5.5"),
    handover: .nothing,
    at: createdAt.addingTimeInterval(120)
  )
  // No identifier yet: the new agent has not revealed one.
  #expect(session.conversations.map(\.resumeIdentifier) == ["claude-1"])

  var agent = try #require(session.agent)
  agent.resumeIdentifier = "codex-1"
  session.agent = agent
  // Same provider, another model: the conversation goes on, and is listed once.
  try session.switchAgent(
    to: SessionAgentConfiguration(
      providerID: "codex", modelID: "gpt-5.5-mini", resumeIdentifier: "codex-1"),
    handover: .resumedConversation,
    at: createdAt.addingTimeInterval(180)
  )

  #expect(session.conversations.map(\.resumeIdentifier) == ["claude-1", "codex-1"])
  #expect(session.conversations.map(\.providerID) == ["claude-code", "codex"])
}
