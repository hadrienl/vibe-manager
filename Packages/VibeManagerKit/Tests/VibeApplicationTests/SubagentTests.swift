import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Lines `agent:<text>`, `tool:<name>`, and `sub:<call id>:running|done[:<seconds since 1970>]`:
/// a sub-agent call, started then when a time is given, the same call again to change its state.
private final class ScriptDecoder: ConversationDecoding {
  private(set) var entries: [ConversationEntry] = []
  private let file: String

  init(file: String) {
    self.file = file
  }

  func consume(_ record: TranscriptRecord) {
    let text = record.text
    let id = "\(file)#\(entries.count)"
    if text.hasPrefix("agent:") {
      entries.append(ConversationEntry(id: id, content: .agentText(String(text.dropFirst(6)))))
    } else if text.hasPrefix("tool:") {
      entries.append(
        ConversationEntry(
          id: id,
          content: .tool(
            ToolCall(callID: id, kind: .other(String(text.dropFirst(5))), state: .succeeded))))
    } else if text.hasPrefix("sub:") {
      let parts = text.split(separator: ":").map(String.init)
      let callID = parts[1]
      let state: ToolCallState = parts[2] == "done" ? .succeeded : .running
      let call = ToolCall(
        callID: callID, kind: .subagent, state: state,
        parameters: [ToolParameter(.description, callID)],
        subagent: SubagentRun(
          agentID: "agent-\(callID)", mode: .background,
          startedAt: parts.count > 3
            ? Double(parts[3]).map { Date(timeIntervalSince1970: $0) } : nil))
      if let index = entries.firstIndex(where: { $0.id == callID }) {
        entries[index].content = .tool(call)
      } else {
        entries.append(ConversationEntry(id: callID, content: .tool(call)))
      }
    }
  }
}

private struct ScriptProvider: AgentProvider, AgentConversationReporting {
  let descriptor = AgentDescriptor(id: AgentProviderID("script"), displayName: "Script")
  let root: URL

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentAvailability(
      state: .available, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "", probedAt: Date(), remediations: []))
  }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw CancellationError()
  }
  func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] { [root] }
  func conversationDecoder(for file: URL) -> any ConversationDecoding {
    ScriptDecoder(file: file.lastPathComponent)
  }
  var promptFormat: AgentPromptFormat { AgentPromptFormat() }

  /// Every call `s<n>` has its transcript `/t/sub/s<n>.jsonl`, naming it.
  func subagentTranscripts(beside root: URL, agentIDs: Set<String>) -> [SubagentTranscriptInfo] {
    (0..<60).map { index in
      SubagentTranscriptInfo(
        agentID: "agent-s\(index)", toolUseID: "s\(index)", file: Self.transcript("s\(index)"))
    }
  }

  static func transcript(_ callID: String) -> URL {
    URL(fileURLWithPath: "/t/sub/\(callID).jsonl")
  }
}

private struct OneProvider: AgentProviderResolving {
  let provider: ScriptProvider
  func descriptors() async -> [AgentDescriptor] { [provider.descriptor] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { provider }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

/// A tail that remembers every file it was asked for.
private actor RecordingTail: TranscriptTailing {
  private var contents: [URL: [String]]
  private var continuations: [URL: AsyncStream<TranscriptChunk>.Continuation] = [:]
  private(set) var opened: [URL] = []

  init(_ contents: [URL: [String]]) {
    self.contents = contents
  }

  nonisolated func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<
    TranscriptChunk
  > {
    let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    Task { await self.opened(file, continuation) }
    return stream
  }

  private func opened(_ file: URL, _ continuation: AsyncStream<TranscriptChunk>.Continuation) {
    opened.append(file)
    continuations[file] = continuation
    continuation.yield(.lines(contents[file] ?? []))
  }

  func read(_ file: URL) async -> [TranscriptRecord] {
    opened.append(file)
    return (contents[file] ?? []).map(TranscriptRecord.init(text:))
  }

  func write(_ lines: [String], to file: URL) {
    contents[file, default: []].append(contentsOf: lines)
    continuations[file]?.yield(.lines(lines))
  }
}

@Suite("Reading sub-agents' transcripts only when they are needed")
struct SubagentFollowTests {
  private let root = URL(fileURLWithPath: "/t/main.jsonl")

  private func next(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator,
    until condition: (ConversationSnapshot) -> Bool
  ) async -> ConversationSnapshot? {
    while let snapshot = await iterator.next() {
      if condition(snapshot) { return snapshot }
    }
    return nil
  }

  private func session() -> WorkSession {
    WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "script", resumeIdentifier: "main"))
  }

  private func follow(_ tail: RecordingTail) -> FollowConversation {
    FollowConversation(
      agents: OneProvider(provider: ScriptProvider(root: root)), tail: tail,
      refreshInterval: .milliseconds(50), publishInterval: .milliseconds(10))
  }

  private func run(_ callID: String, in snapshot: ConversationSnapshot?) -> SubagentRun? {
    snapshot?.entries.first { $0.id == callID }?.toolCall?.subagent
  }

  @Test("Fifty sub-agents that are done: none of their transcripts is opened")
  func finishedAreNotRead() async throws {
    let lines = (0..<50).map { "sub:s\($0):done" } + ["agent:all done"]
    let tail = RecordingTail([root: lines])
    let follow = follow(tail)
    var iterator = await follow.follow(session()).makeAsyncIterator()
    let snapshot = await next(&iterator) { $0.entries.count == 51 }
    #expect(snapshot?.entries.compactMap(\.subagentCall).count == 50)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await tail.opened == [root])
    #expect(run("s0", in: snapshot)?.activity == .unread)
  }

  @Test("A sub-agent at work is followed, its activity shown as it is written")
  func runningIsFollowed() async throws {
    let sub = ScriptProvider.transcript("s1")
    let tail = RecordingTail([root: ["sub:s1:running"], sub: ["tool:Read"]])
    let follow = follow(tail)
    var iterator = await follow.follow(session()).makeAsyncIterator()
    let first = await next(&iterator) { run("s1", in: $0)?.activityEntries?.count == 1 }
    #expect(run("s1", in: first)?.transcript == sub)
    #expect(run("s1", in: first)?.depth == 1)
    await tail.write(["tool:Grep", "agent:found it"], to: sub)
    let second = await next(&iterator) { run("s1", in: $0)?.activityEntries?.count == 3 }
    #expect(second != nil)
    // Done: what it said last is its answer, the main transcript giving none.
    await tail.write(["sub:s1:done"], to: root)
    let done = await next(&iterator) { run("s1", in: $0)?.result == "found it" }
    #expect(done != nil)
  }

  @Test("A sub-agent that is done is read once its activity is unfolded")
  func unfoldedIsRead() async throws {
    let sub = ScriptProvider.transcript("s2")
    let tail = RecordingTail([root: ["sub:s1:done", "sub:s2:done"], sub: ["agent:hello"]])
    let follow = follow(tail)
    let session = session()
    var iterator = await follow.follow(session).makeAsyncIterator()
    _ = await next(&iterator) { $0.entries.count == 2 }
    await follow.setUnfoldedSubagents(["s2"], for: session.id)
    let read = await next(&iterator) { run("s2", in: $0)?.activityEntries?.count == 1 }
    #expect(read != nil)
    #expect(run("s1", in: read)?.activity == .unread)
    #expect(await tail.opened.contains(ScriptProvider.transcript("s1")) == false)
  }

  @Test("A sub-agent that is done and has no transcript says so, and is not looked for again")
  func notFound() async throws {
    let tail = RecordingTail([root: ["sub:zz:done"]])
    let follow = follow(tail)
    let session = session()
    var iterator = await follow.follow(session).makeAsyncIterator()
    _ = await next(&iterator) { $0.entries.count == 1 }
    await follow.setUnfoldedSubagents(["zz"], for: session.id)
    let missing = await next(&iterator) { run("zz", in: $0)?.activity == .notFound }
    #expect(missing != nil)
  }

  @Test("Under a sub-agent that ended, one still waiting is stopped, and not followed")
  func underAnEndedSubagent() async throws {
    let tail = RecordingTail([
      root: ["sub:s1:done"], ScriptProvider.transcript("s1"): ["sub:s2:running"],
      ScriptProvider.transcript("s2"): ["tool:Read"],
    ])
    let follow = follow(tail)
    let session = session()
    var iterator = await follow.follow(session).makeAsyncIterator()
    _ = await next(&iterator) { $0.entries.count == 1 }
    await follow.setUnfoldedSubagents(["s1"], for: session.id)
    let read = await next(&iterator) { run("s1", in: $0)?.activityEntries?.count == 1 }
    let inner = run("s1", in: read)?.activityEntries?.first?.toolCall
    #expect(inner?.state == .interrupted)
    let running = ConversationEntry.runningSubagents(in: read?.entries ?? [])
    #expect(running.isEmpty)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await tail.opened.contains(ScriptProvider.transcript("s2")) == false)
  }

  @Test("A sub-agent an earlier process of the agent started is not followed once resumed")
  func earlierProcess() async throws {
    let tail = RecordingTail([
      root: ["sub:s1:running:1000", "sub:s2:running:3000"],
      ScriptProvider.transcript("s1"): ["tool:Read"],
      ScriptProvider.transcript("s2"): ["tool:Read"],
    ])
    let follow = follow(tail)
    let session = session()
    await follow.setAgentRunning(true, since: Date(timeIntervalSince1970: 2_000), for: session.id)
    // The model's first word, before it could date the process, does not drop the date.
    await follow.setAgentRunning(true, for: session.id)
    var iterator = await follow.follow(session).makeAsyncIterator()
    let snapshot = await next(&iterator) { run("s2", in: $0)?.activityEntries?.count == 1 }
    #expect(run("s1", in: snapshot)?.activity == .unread)
    try await Task.sleep(for: .milliseconds(150))
    #expect(await tail.opened.contains(ScriptProvider.transcript("s1")) == false)
  }

  @Test("In a session whose agent stopped, a sub-agent that never ended is not opened")
  func stoppedAgent() async throws {
    let tail = RecordingTail([
      root: ["sub:s1:running"], ScriptProvider.transcript("s1"): ["tool:Read"],
    ])
    let follow = follow(tail)
    let session = session()
    await follow.setAgentRunning(false, for: session.id)
    var iterator = await follow.follow(session).makeAsyncIterator()
    let snapshot = await next(&iterator) { $0.entries.count == 1 }
    try await Task.sleep(for: .milliseconds(150))
    #expect(run("s1", in: snapshot)?.activity == .unread)
    #expect(await tail.opened == [root])
    // Running again: followed.
    await follow.setAgentRunning(true, for: session.id)
    let followed = await next(&iterator) { run("s1", in: $0)?.activityEntries?.count == 1 }
    #expect(followed != nil)
  }
}

@Suite("Tying sub-agents to their transcripts")
struct SubagentLinkerTests {
  private func file(_ name: String) -> URL { URL(fileURLWithPath: "/s/\(name).jsonl") }

  @Test("The call a transcript names, even among several started together")
  func byToolUse() {
    let transcripts = [
      SubagentTranscriptInfo(agentID: "b", toolUseID: "t2", file: file("b")),
      SubagentTranscriptInfo(agentID: "a", toolUseID: "t1", file: file("a")),
      SubagentTranscriptInfo(agentID: "c", toolUseID: "t3", file: file("c")),
    ]
    let links = SubagentLinker.link(
      [.init(callID: "t1"), .init(callID: "t2"), .init(callID: "t3")], among: transcripts
    ) { _ in nil }
    #expect(links["t1"]?.agentID == "a")
    #expect(links["t2"]?.agentID == "b")
    #expect(links["t3"]?.agentID == "c")
  }

  @Test("The sub-agent's identifier, once its call returned it")
  func byAgentID() {
    let transcripts = [SubagentTranscriptInfo(agentID: "a9", file: file("a9"))]
    let links = SubagentLinker.link([.init(callID: "t1", agentID: "a9")], among: transcripts) {
      _ in nil
    }
    #expect(links["t1"]?.file == file("a9"))
  }

  @Test("A transcript naming nothing: the same prompt, in the order they started")
  func byPrompt() {
    let start = Date(timeIntervalSince1970: 1_000)
    let transcripts = [
      SubagentTranscriptInfo(agentID: "x", file: file("x"), createdAt: start.addingTimeInterval(2)),
      SubagentTranscriptInfo(agentID: "y", file: file("y"), createdAt: start.addingTimeInterval(1)),
      SubagentTranscriptInfo(agentID: "z", file: file("z"), createdAt: start.addingTimeInterval(3)),
    ]
    let prompts = [file("x"): "same", file("y"): "same", file("z"): "other"]
    let links = SubagentLinker.link(
      [
        .init(callID: "t1", prompt: "same", date: start),
        .init(callID: "t2", prompt: "same", date: start),
        .init(callID: "t3", prompt: "unknown", date: start),
      ],
      among: transcripts
    ) { prompts[$0] }
    #expect(links["t1"]?.agentID == "y")
    #expect(links["t2"]?.agentID == "x")
    #expect(links["t3"] == nil)
  }

  @Test("Never a transcript written before its call, nor one tied to another call")
  func noGuess() {
    let start = Date(timeIntervalSince1970: 1_000)
    let transcripts = [
      SubagentTranscriptInfo(
        agentID: "old", file: file("old"), createdAt: start.addingTimeInterval(-60)),
      SubagentTranscriptInfo(
        agentID: "named", toolUseID: "other", file: file("named"), createdAt: start),
    ]
    let links = SubagentLinker.link(
      [.init(callID: "t1", prompt: "p", date: start)], among: transcripts
    ) { _ in "p" }
    #expect(links.isEmpty)
  }
}

@Suite("Sub-agents in the conversation's blocks")
struct SubagentBlockTests {
  private func subagent(
    _ id: String, _ state: ToolCallState = .running, inner: [ConversationEntry]? = nil
  )
    -> ConversationEntry
  {
    ConversationEntry(
      id: id,
      content: .tool(
        ToolCall(
          callID: id, kind: .subagent, state: state,
          subagent: SubagentRun(
            agentID: "agent-\(id)", activity: inner.map(SubagentActivity.read) ?? .unread))))
  }

  private func tool(_ id: String, _ state: ToolCallState = .running) -> ConversationEntry {
    ConversationEntry(id: id, content: .tool(ToolCall(callID: id, kind: .shell, state: state)))
  }

  @Test("Started together, folded together — even with the grouping of tools off")
  func grouped() {
    let entries = [
      subagent("a"), subagent("b", .succeeded), subagent("c"),
      ConversationEntry(id: "t", content: .agentText("meanwhile")), subagent("d"),
    ]
    for grouping in [true, false] {
      let blocks = ConversationGrouping.blocks(entries, grouping: grouping)
      #expect(blocks.map(\.id) == ["subagents:a", "t", "d"])
      #expect(blocks[0].calls.map(\.callID) == ["a", "b", "c"])
      #expect(blocks[0].toolState == .running)
    }
  }

  @Test("A permission a sub-agent asks for marks its own call, not the agent's")
  func permissionOfASubagent() {
    let entries = [
      tool("main"),
      subagent("s", inner: [tool("inner")]),
    ]
    let marked = ConversationEntry.markingPendingPermission(
      entries, activity: .awaitingUser(.approval), agentID: "agent-s")
    #expect(marked[0].toolCall?.state == .running)
    #expect(marked[1].toolCall?.state == .awaitingPermission)
    #expect(
      marked[1].toolCall?.subagent?.activityEntries?.first?.toolCall?.state == .awaitingPermission)
    // The agent's own request never lands on a sub-agent running beside it.
    let own = ConversationEntry.markingPendingPermission(
      entries, activity: .awaitingUser(.approval))
    #expect(own[0].toolCall?.state == .awaitingPermission)
    #expect(own[1].toolCall?.state == .running)
  }

  @Test("Running sub-agents at any depth, and one found by its identifier")
  func findingSubagents() {
    let entries = [
      subagent("a", .succeeded, inner: [subagent("a1"), subagent("a2", .succeeded)]),
      subagent("b"),
    ]
    #expect(ConversationEntry.runningSubagents(in: entries).map(\.callID) == ["a1", "b"])
    #expect(ConversationEntry.subagent(agentID: "agent-a2", in: entries)?.callID == "a2")
  }

  @Test("The summary of an activity: tools, files edited, the last actions")
  func summary() {
    let edit = ToolCall(
      callID: "e", kind: .edit, state: .succeeded, parameters: [ToolParameter(.path, "/a.swift")])
    let entries = [
      tool("1", .succeeded), tool("2", .succeeded),
      ConversationEntry(id: "e", content: .tool(edit)), tool("3", .succeeded),
    ]
    let summary = SubagentActivitySummary(entries: entries)
    #expect(summary.toolCount == 4)
    #expect(summary.editedFileCount == 1)
    #expect(summary.lastActions.map(\.callID) == ["2", "e", "3"])
  }
}
