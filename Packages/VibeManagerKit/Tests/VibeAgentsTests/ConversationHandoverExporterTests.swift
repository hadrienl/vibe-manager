import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("Copying conversations for another agent")
struct ConversationHandoverExporterTests {
  private func fixture() throws -> (URL, URL, ConversationHandoverExporter) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Handover-\(UUID())")
    let projects = root.appendingPathComponent("projects")
    let project = projects.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return (
      root, project,
      ConversationHandoverExporter(
        directory: root.appendingPathComponent("copies"),
        locator: AgentTranscriptLocator(
          claudeProjects: projects, codexSessions: root.appendingPathComponent("sessions")))
    )
  }

  @Test(
    "Tool results and large logs survive deletion of the source; each snapshot stays independent")
  func durableSnapshot() async throws {
    let (root, project, exporter) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = project.appendingPathComponent("thread.jsonl")
    let data = Data((String(repeating: "{\"tool_result\":\"résultat\"}\n", count: 10_000)).utf8)
    try data.write(to: source)
    let session = WorkSession(
      name: "Audit",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "thread"))
    let first = try await exporter.export(session)
    try Data("new conversation\n".utf8).write(to: source)
    let second = try await exporter.export(session)
    try FileManager.default.removeItem(at: source)
    #expect(first.index != second.index)
    #expect(first.byteCount == data.count)
    #expect(
      try Data(
        contentsOf: first.index.deletingLastPathComponent().appendingPathComponent("1.jsonl"))
        == data)
    #expect(
      try String(
        contentsOf: second.index.deletingLastPathComponent().appendingPathComponent("1.jsonl"),
        encoding: .utf8) == "new conversation\n")
    #expect(first.prompt.utf8.count < 2048)
    let permissions = try FileManager.default.attributesOfItem(atPath: first.index.path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("All conversations, native endpoint harnesses and Claude sub-agents are copied in order")
  func historyAndSubagents() async throws {
    let (root, project, exporter) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let created = Date().addingTimeInterval(-60)
    let subagents = project.appendingPathComponent("old/subagents")
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    try Data("main\n".utf8).write(to: project.appendingPathComponent("old.jsonl"))
    try Data("child\n".utf8).write(to: subagents.appendingPathComponent("agent-1.jsonl"))
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    let day = String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let codex = root.appendingPathComponent("sessions/\(day)")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try Data("codex\n".utf8).write(to: codex.appendingPathComponent("rollout-new.jsonl"))
    var session = WorkSession(
      name: "Audit",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "old"),
      createdAt: created, updatedAt: created, startedAt: created)
    try session.switchAgent(
      to: SessionAgentConfiguration(
        providerID: "endpoint:test", resumeIdentifier: "new", harnessID: "codex"),
      handover: .summary(byteCount: 1, isTruncated: false, wasEdited: false),
      at: created.addingTimeInterval(1))
    let result = try await exporter.export(session)
    let folder = result.index.deletingLastPathComponent()
    #expect(
      try String(contentsOf: folder.appendingPathComponent("1.jsonl"), encoding: .utf8) == "main\n")
    #expect(
      try String(contentsOf: folder.appendingPathComponent("2.jsonl"), encoding: .utf8) == "child\n"
    )
    #expect(
      try String(contentsOf: folder.appendingPathComponent("3.jsonl"), encoding: .utf8) == "codex\n"
    )
    let index = try String(contentsOf: result.index, encoding: .utf8)
    #expect(index.contains("agent-1.jsonl"))
    #expect(index.contains("endpoint:test / codex / new"))
  }

  @Test("Codex child rollouts are copied recursively without looping on repeated references")
  func codexSubagents() async throws {
    let (root, project, exporter) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    let day = String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let folder = root.appendingPathComponent("sessions/\(day)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let activity =
      #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"SubAgentActivity","agent_thread_id":"child","kind":"started"}}}"#
      + "\n"
    try Data(activity.utf8).write(to: folder.appendingPathComponent("rollout-parent.jsonl"))
    try Data(activity.utf8).write(to: folder.appendingPathComponent("rollout-child.jsonl"))
    let session = WorkSession(
      name: "Test",
      agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: "parent"))
    let result = try await exporter.export(session)
    let index = try String(contentsOf: result.index, encoding: .utf8)
    #expect(index.contains("codex / sub-agent / child"))
    let files = try FileManager.default.contentsOfDirectory(
      atPath: result.index.deletingLastPathComponent().path)
    #expect(files.sorted() == ["1.jsonl", "2.jsonl", "history.md"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
  }

  @Test("An extra account exports its own conversation, even if the default home has a copy")
  func accountHome() async throws {
    let (root, project, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("default\n".utf8).write(to: project.appendingPathComponent("thread.jsonl"))
    let account = root.appendingPathComponent("account")
    let accountProject = account.appendingPathComponent("projects/project")
    try FileManager.default.createDirectory(at: accountProject, withIntermediateDirectories: true)
    try Data("account\n".utf8).write(to: accountProject.appendingPathComponent("thread.jsonl"))
    let homes = AgentHomes()
    homes.replace(claudeHomes: ["account.1": account], codexHomes: [:])
    let exporter = ConversationHandoverExporter(
      directory: root.appendingPathComponent("copies"),
      locator: AgentTranscriptLocator(
        claudeProjects: project.deletingLastPathComponent(), homes: homes))
    let session = WorkSession(
      name: "Test",
      agent: SessionAgentConfiguration(
        providerID: "account.1", resumeIdentifier: "thread", harnessID: "claude-code"))
    let result = try await exporter.export(session)
    #expect(
      try String(
        contentsOf: result.index.deletingLastPathComponent().appendingPathComponent("1.jsonl"),
        encoding: .utf8) == "account\n")
  }

  @Test("Missing logs refuse the handover, while partially available history is labelled")
  func missingLogs() async throws {
    let (root, project, exporter) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let created = Date()
    var session = WorkSession(
      name: "Missing",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "missing"),
      createdAt: created, updatedAt: created, startedAt: created)
    await #expect(throws: ConversationHandoverError.unavailable) {
      try await exporter.export(session)
    }
    try session.switchAgent(
      to: SessionAgentConfiguration(
        providerID: "claude-code", modelID: "other", resumeIdentifier: "available"),
      handover: .nothing, at: created.addingTimeInterval(1))
    try Data("available\n".utf8).write(to: project.appendingPathComponent("available.jsonl"))
    let partial = try await exporter.export(session)
    #expect(try String(contentsOf: partial.index, encoding: .utf8).contains("history is partial"))
  }

  @Test("A symbolic link is refused, and an incomplete export is removed")
  func symbolicLink() async throws {
    let (root, project, exporter) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("private.jsonl")
    try Data("private\n".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: project.appendingPathComponent("thread.jsonl"), withDestinationURL: target)
    let session = WorkSession(
      name: "Test",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "thread"))
    await #expect(throws: ConversationHandoverError.cannotCopy) {
      try await exporter.export(session)
    }
    let snapshots = root.appendingPathComponent("copies/\(session.id)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
  }

  @Test("A destination that cannot be created refuses without altering the source")
  func copyFailure() async throws {
    let (root, project, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = project.appendingPathComponent("thread.jsonl")
    try Data("original\n".utf8).write(to: source)
    let blocked = root.appendingPathComponent("file")
    try Data().write(to: blocked)
    let exporter = ConversationHandoverExporter(
      directory: blocked,
      locator: AgentTranscriptLocator(
        claudeProjects: project.deletingLastPathComponent(), codexSessions: root))
    let session = WorkSession(
      name: "Test",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "thread"))
    await #expect(throws: ConversationHandoverError.cannotCopy) {
      try await exporter.export(session)
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "original\n")
  }
}
