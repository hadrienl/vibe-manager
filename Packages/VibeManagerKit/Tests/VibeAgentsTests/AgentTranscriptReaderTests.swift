import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("Reading what an agent did from its transcript")
struct AgentTranscriptReaderTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeTranscripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func session(provider: String, identifier: String) -> WorkSession {
    WorkSession(
      name: "Session",
      agent: SessionAgentConfiguration(providerID: provider, resumeIdentifier: identifier))
  }

  private func append(_ lines: [String], to file: URL) throws {
    let text = lines.joined(separator: "\n") + "\n"
    if let handle = try? FileHandle(forWritingTo: file) {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
    } else {
      try Data(text.utf8).write(to: file)
    }
  }

  @Test("Claude Code: the cwd of every line, the files its tools wrote, its sub-agents too")
  func claudeCode() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "28538616-9a27-4cae-92a7-150d7511fc9d"
    let folder = root.appendingPathComponent("projects/-Users-a-Projects", isDirectory: true)
    let subagents = folder.appendingPathComponent("\(identifier)/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    let main = folder.appendingPathComponent("\(identifier).jsonl")
    try append(
      [
        #"{"type":"user","cwd":"/Users/a/Projects","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"assistant","cwd":"/Users/a/Projects/api","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/a/Projects/api/a.swift"}},{"type":"tool_use","name":"Read","input":{"file_path":"/Users/a/Projects/web/b.swift"}}]}}"#,
      ], to: main)
    try append(
      [
        #"{"cwd":"/Users/a/Projects/lib","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/a/Projects/lib/c.swift"}}]}}"#
      ], to: subagents.appendingPathComponent("agent-1.jsonl"))
    let reader = AgentTranscriptReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))

    let first = try #require(
      await reader.activity(for: session(provider: "claude-code", identifier: identifier)))

    #expect(
      first.editedPaths == ["/Users/a/Projects/api/a.swift", "/Users/a/Projects/lib/c.swift"])
    #expect(
      first.workingDirectories
        == ["/Users/a/Projects", "/Users/a/Projects/api", "/Users/a/Projects/lib"])

    // Read again after the agent wrote more: only the new lines are read, the rest is kept.
    try append(
      [#"{"cwd":"/Users/a/Projects/web","message":{"content":[]}}"#, #"{"cwd":"/Users/a/half"#],
      to: main)
    let second = try #require(
      await reader.activity(for: session(provider: "claude-code", identifier: identifier)))
    #expect(second.workingDirectories.contains("/Users/a/Projects/web"))
    #expect(second.editedPaths.contains("/Users/a/Projects/api/a.swift"))
    #expect(!second.workingDirectories.contains("/Users/a/half"))
  }

  @Test("Codex: the workdir of its commands and the files its patches touch")
  func codex() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0cd8c-0224-7721-8fff-e7b7647eff14"
    let parts = Calendar(identifier: .gregorian).dateComponents(
      in: .current, from: Date())
    let day = root.appendingPathComponent(
      String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
      isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try append(
      [
        #"{"type":"session_meta","payload":{"id":"x","cwd":"/Users/a/vibe"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"tools.exec_command({\"cmd\":\"git status\",\"workdir\":\"/Users/a/other\"})"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n*** Add File: /Users/a/abs/New.swift\n*** End Patch"}}"#,
      ], to: day.appendingPathComponent("rollout-2026-09-23T09-15-00-\(identifier).jsonl"))
    let reader = AgentTranscriptReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))
    let session = WorkSession(
      name: "Codex",
      agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: identifier))

    let activity = try #require(await reader.activity(for: session))

    #expect(activity.workingDirectories == ["/Users/a/vibe", "/Users/a/other"])
    #expect(activity.editedPaths == ["/Users/a/other/Sources/App.swift", "/Users/a/abs/New.swift"])
  }

  @Test("No identifier, or no file, is no transcript")
  func nothingToRead() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = AgentTranscriptReader(
      claudeProjects: root.appendingPathComponent("projects"),
      codexSessions: root.appendingPathComponent("sessions"))

    #expect(await reader.activity(for: WorkSession(name: "Bare")) == nil)
    #expect(
      await reader.activity(for: session(provider: "claude-code", identifier: "missing")) == nil)
  }

  @Test("The whole transcript folder is watched, even before the agent wrote its first line")
  func watchedFolders() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = root.appendingPathComponent("projects")
    let sessions = root.appendingPathComponent("sessions")
    let reader = AgentTranscriptReader(claudeProjects: projects, codexSessions: sessions)

    #expect(
      await reader.transcriptDirectories(for: session(provider: "claude-code", identifier: "new"))
        == [projects.path])
    #expect(
      await reader.transcriptDirectories(for: session(provider: "codex", identifier: "019e"))
        == [sessions.path])
    #expect(await reader.transcriptDirectories(for: WorkSession(name: "Bare")).isEmpty)
  }

  @Test("After a switch of agent, the work of the previous one is still read and watched")
  func everyConversationIsRead() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = "28538616-9a27-4cae-92a7-150d7511fc9d"
    let codex = "01a0cd8c-0224-7721-8fff-e7b7647eff14"
    let folder = root.appendingPathComponent("projects/-Users-a-Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try append(
      [
        #"{"cwd":"/Users/a/Projects/api","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/a/Projects/api/a.swift"}}]}}"#
      ], to: folder.appendingPathComponent("\(claude).jsonl"))
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    let day = root.appendingPathComponent(
      String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
      isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try append(
      [#"{"type":"session_meta","payload":{"id":"x","cwd":"/Users/a/Projects/web"}}"#],
      to: day.appendingPathComponent("rollout-2026-09-23T09-15-00-\(codex).jsonl"))
    let projects = root.appendingPathComponent("projects")
    let sessions = root.appendingPathComponent("sessions")
    let reader = AgentTranscriptReader(claudeProjects: projects, codexSessions: sessions)

    var switched = WorkSession(
      name: "Switched",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: claude),
      startedAt: Date())
    try switched.switchAgent(
      to: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: codex),
      handover: .nothing,
      at: Date())

    let activity = try #require(await reader.activity(for: switched))

    #expect(activity.editedPaths == ["/Users/a/Projects/api/a.swift"])
    #expect(activity.workingDirectories == ["/Users/a/Projects/api", "/Users/a/Projects/web"])
    #expect(await reader.transcriptDirectories(for: switched) == [projects.path, sessions.path])
  }

  @Test("Claude Code: once found, the projects are not listed again, but new sub-agents are seen")
  func claudeFilesRemembered() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "7d1e4b5a-0000-4000-8000-000000000001"
    let projects = root.appendingPathComponent("projects")
    let folder = projects.appendingPathComponent("-Users-a-api", isDirectory: true)
    let subagents = folder.appendingPathComponent("\(identifier)/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    let main = folder.appendingPathComponent("\(identifier).jsonl")
    try append([#"{"cwd":"/Users/a/api","message":{"content":[]}}"#], to: main)
    let listings = ListingCounter()
    // A still clock: a runner that stalls past `relistInterval` must not list the folders again.
    let moment = Date()
    let reader = AgentTranscriptReader(
      claudeProjects: projects, codexSessions: root.appendingPathComponent("sessions"),
      list: { listings.list($0) }, now: { moment })
    let conversation = session(provider: "claude-code", identifier: identifier)

    _ = await reader.activity(for: conversation)
    for _ in 0..<10 { _ = await reader.activity(for: conversation) }
    #expect(listings.count(of: projects) == 1)

    try append(
      [#"{"cwd":"/Users/a/lib","message":{"content":[]}}"#],
      to: subagents.appendingPathComponent("agent-2.jsonl"))
    let activity = try #require(await reader.activity(for: conversation))
    #expect(activity.workingDirectories.contains("/Users/a/lib"))
    #expect(listings.count(of: projects) == 1)

    // Gone: every project folder is listed again.
    try FileManager.default.removeItem(at: main)
    _ = await reader.activity(for: conversation)
    #expect(listings.count(of: projects) == 2)
  }

  @Test("Codex: once a rollout is found, only the recent days are listed again")
  func codexFilesRemembered() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "01a0cd8c-0224-7721-8fff-000000000002"
    let sessions = root.appendingPathComponent("sessions")
    let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
    let day = sessions.appendingPathComponent(
      String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
      isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try append(
      [#"{"type":"session_meta","payload":{"id":"x","cwd":"/Users/a/vibe"}}"#],
      to: day.appendingPathComponent("rollout-2026-09-30T10-00-00-\(identifier).jsonl"))
    let listings = ListingCounter()
    let moment = Date()
    let reader = AgentTranscriptReader(
      claudeProjects: root.appendingPathComponent("projects"), codexSessions: sessions,
      list: { listings.list($0) }, now: { moment })
    // A session of sixty days: the first search walks every one of them.
    let conversation = WorkSession(
      name: "Session",
      agent: SessionAgentConfiguration(providerID: "codex", resumeIdentifier: identifier),
      createdAt: Date().addingTimeInterval(-60 * 86_400))

    _ = await reader.activity(for: conversation)
    let walked = listings.total
    #expect(walked >= 60)

    for _ in 0..<10 { _ = await reader.activity(for: conversation) }
    // Yesterday and today, each time.
    #expect(listings.total - walked <= 10 * 2)
  }
}

/// Lists folders for real, and counts how often each was listed.
private final class ListingCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func list(_ folder: URL) -> [URL]? {
    lock.withLock { counts[folder.standardizedFileURL.path, default: 0] += 1 }
    return AgentTranscriptLocator.contents(of: folder)
  }

  func count(of folder: URL) -> Int {
    lock.withLock { counts[folder.standardizedFileURL.path] ?? 0 }
  }

  var total: Int { lock.withLock { counts.values.reduce(0, +) } }

  @Test("An endpoint's conversation is read where its harness wrote it, an unknown agent is not")
  func endpointReadsItsHarness() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = "5b1f4a86-3c0e-4c43-9d8e-2f0b6f1d7a10"
    let folder = root.appendingPathComponent("projects/-Users-a-Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try append(
      [
        #"{"cwd":"/Users/a/Projects","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/a/Projects/n.swift"}}]}}"#
      ], to: folder.appendingPathComponent("\(identifier).jsonl"))
    let projects = root.appendingPathComponent("projects")
    let reader = AgentTranscriptReader(
      claudeProjects: projects, codexSessions: root.appendingPathComponent("sessions"))
    let endpoint = "endpoint.7C1E6A55-0D5B-4E43-9E47-4A3C2B1D0E9F"

    let driven = WorkSession(
      name: "Endpoint",
      agent: SessionAgentConfiguration(
        providerID: endpoint, resumeIdentifier: identifier, harnessID: "claude-code"))
    let activity = try #require(await reader.activity(for: driven))
    #expect(activity.editedPaths == ["/Users/a/Projects/n.swift"])
    #expect(await reader.transcriptDirectories(for: driven) == [projects.path])

    // Without its harness recorded, nothing says which CLI wrote it.
    let unknown = session(provider: endpoint, identifier: identifier)
    #expect(await reader.activity(for: unknown) == nil)
    #expect(await reader.transcriptDirectories(for: unknown).isEmpty)
  }
}
