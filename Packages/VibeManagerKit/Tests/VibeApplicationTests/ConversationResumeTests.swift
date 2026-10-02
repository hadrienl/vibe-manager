import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Lines of the form `user:<text>` or `agent:<text>`, one entry each.
private final class TextDecoder: ConversationDecoding {
  private(set) var entries: [ConversationEntry] = []

  func consume(_ record: TranscriptRecord) {
    let text = record.object["line"] as? String ?? ""
    let id = "#\(entries.count)"
    if text.hasPrefix("user:") {
      entries.append(
        ConversationEntry(id: id, content: .userPrompt(String(text.dropFirst(5)), attachments: [])))
    } else if text.hasPrefix("agent:") {
      entries.append(ConversationEntry(id: id, content: .agentText(String(text.dropFirst(6)))))
    }
  }
}

private struct TextProvider: AgentProvider, AgentConversationReporting {
  let descriptor = AgentDescriptor(id: AgentProviderID("alpha"), displayName: "Alpha")

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
  ) -> [URL] {
    conversation.resumeIdentifier.map { [URL(fileURLWithPath: "/t/\($0).jsonl")] } ?? []
  }
  func conversationDecoder(for file: URL) -> any ConversationDecoding { TextDecoder() }
  var promptFormat: AgentPromptFormat { AgentPromptFormat() }
}

private struct TextRegistry: AgentProviderResolving {
  func descriptors() async -> [AgentDescriptor] { [TextProvider().descriptor] }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? { TextProvider() }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

/// A tail whose positions count lines, and that tells where each follow started and how many
/// lines it delivered: the work a resume saves.
private actor CountingTail: TranscriptTailing {
  private var contents: [URL: [String]] = [:]
  /// Bumped when a file is replaced under its name.
  private var inodes: [URL: UInt64] = [:]
  private var continuations: [URL: AsyncStream<TranscriptChunk>.Continuation] = [:]
  private(set) var starts: [URL: [UInt64?]] = [:]
  private(set) var delivered = 0

  nonisolated func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<
    TranscriptChunk
  > {
    let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    Task { await self.opened(file, from: position, continuation) }
    return stream
  }

  private func opened(
    _ file: URL, from position: TranscriptPosition?,
    _ continuation: AsyncStream<TranscriptChunk>.Continuation
  ) {
    starts[file, default: []].append(position?.offset)
    continuations[file] = continuation
    var start = Int(position?.offset ?? 0)
    if let position, position.inode != inode(of: file) {
      continuation.yield(.reset)
      start = 0
    }
    deliver(Array((contents[file] ?? []).dropFirst(start)), of: file, to: continuation)
  }

  private func inode(of file: URL) -> UInt64 { inodes[file] ?? 1 }

  private func deliver(
    _ lines: [String], of file: URL, to continuation: AsyncStream<TranscriptChunk>.Continuation
  ) {
    delivered += lines.count
    let position = TranscriptPosition(
      inode: inode(of: file), offset: UInt64(contents[file]?.count ?? 0), fingerprint: Data())
    continuation.yield(
      .records(
        lines.map { TranscriptRecord(["line": $0]) }, through: position, isCaughtUp: true))
  }

  func read(_ file: URL) async -> [TranscriptRecord] {
    (contents[file] ?? []).map { TranscriptRecord(["line": $0]) }
  }

  /// Appended, and handed to the follow under way if there is one.
  func write(_ lines: [String], to file: URL, live: Bool = true) {
    contents[file, default: []] += lines
    if live, let continuation = continuations[file] {
      deliver(lines, of: file, to: continuation)
    }
  }

  /// Replaced under its name while nothing followed it.
  func replace(_ file: URL, with lines: [String]) {
    contents[file] = lines
    inodes[file] = inode(of: file) + 1
  }

  func resetCounts() {
    starts = [:]
    delivered = 0
  }
}

/// What a follow published, kept by a task that can be cancelled like a model's.
private actor Snapshots {
  private(set) var all: [ConversationSnapshot] = []
  func add(_ snapshot: ConversationSnapshot) { all.append(snapshot) }
  var last: ConversationSnapshot? { all.last }
}

@Suite("Resuming a conversation where its reading stopped (#249)")
struct ConversationResumeTests {
  private func session(_ name: String) -> WorkSession {
    WorkSession(
      name: name, agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: name))
  }

  private func file(_ name: String) -> URL { URL(fileURLWithPath: "/t/\(name).jsonl") }

  private func makeFollow(_ tail: CountingTail) -> FollowConversation {
    FollowConversation(
      agents: TextRegistry(), tail: tail, refreshInterval: .milliseconds(50),
      publishInterval: .milliseconds(10))
  }

  /// Follows `session` until `condition` holds, then ends the follow as a model paused does.
  private func follow(
    _ session: WorkSession, with follow: FollowConversation,
    until condition: @escaping @Sendable (ConversationSnapshot) -> Bool
  ) async -> [ConversationSnapshot] {
    let snapshots = Snapshots()
    let stream = await follow.follow(session)
    let consumer = Task {
      for await snapshot in stream { await snapshots.add(snapshot) }
    }
    #expect(await eventually { await snapshots.last.map(condition) == true })
    consumer.cancel()
    #expect(await eventually { await follow.followCount == 0 })
    return await snapshots.all
  }

  @Test(
    "Followed again, the conversation is there at once, and only what was written meanwhile is read"
  )
  func resumes() async {
    let tail = CountingTail()
    let follow = makeFollow(tail)
    let one = session("one")
    await tail.write(["user:hi", "agent:hello"], to: file("one"))
    _ = await self.follow(one, with: follow) { $0.entries.count == 2 }
    #expect(await follow.parkedSessionIDs == [one.id])
    await tail.write(["agent:later"], to: file("one"), live: false)
    await tail.resetCounts()

    let snapshots = await self.follow(one, with: follow) { $0.entries.count == 3 }
    // Never a placeholder: what was read is shown before anything new is.
    #expect(snapshots.first?.availability == .available)
    #expect(snapshots.allSatisfy { $0.entries.count >= 2 })
    #expect(
      snapshots.last?.entries.map(\.content) == [
        .userPrompt("hi", attachments: []), .agentText("hello"), .agentText("later"),
      ])
    #expect(await tail.starts[file("one")] == [2])
    #expect(await tail.delivered == 1)
    #expect(await follow.parkedSessionIDs == [one.id])
  }

  @Test("A file replaced meanwhile is read again, what was shown staying until it is")
  func replacedMeanwhile() async {
    let tail = CountingTail()
    let follow = makeFollow(tail)
    let one = session("one")
    await tail.write(["user:hi", "agent:hello"], to: file("one"))
    _ = await self.follow(one, with: follow) { $0.entries.count == 2 }
    await tail.replace(file("one"), with: ["user:again"])

    let snapshots = await self.follow(one, with: follow) { $0.entries.count == 1 }
    #expect(snapshots.allSatisfy { !$0.entries.isEmpty })
    #expect(snapshots.last?.entries.map(\.content) == [.userPrompt("again", attachments: [])])
  }

  @Test("Once forgotten, a session is read from the start again")
  func forgotten() async {
    let tail = CountingTail()
    let follow = makeFollow(tail)
    let one = session("one")
    await tail.write(["user:hi", "agent:hello"], to: file("one"))
    _ = await self.follow(one, with: follow) { $0.entries.count == 2 }
    await follow.forget(one.id)
    #expect(await follow.parkedSessionIDs.isEmpty)
    await tail.resetCounts()

    _ = await self.follow(one, with: follow) { $0.entries.count == 2 }
    #expect(await tail.starts[file("one")] == [nil])
    #expect(await tail.delivered == 2)
  }

  @Test("Forgotten while its follow is ending, nothing of the session is put aside")
  func forgottenWhileEnding() async {
    let tail = CountingTail()
    let follow = makeFollow(tail)
    let one = session("one")
    await tail.write(["user:hi"], to: file("one"))
    let snapshots = Snapshots()
    let stream = await follow.follow(one)
    let consumer = Task {
      for await snapshot in stream { await snapshots.add(snapshot) }
    }
    #expect(await eventually { await snapshots.last?.entries.count == 1 })
    // The model let go of: its follow ends after the workspace said to forget it.
    await follow.forget(one.id)
    consumer.cancel()
    #expect(await eventually { await follow.followCount == 0 })
    #expect(await follow.parkedSessionIDs.isEmpty)
  }

  @Test("No more sessions are put aside than models are kept asleep")
  func bounded() async {
    let tail = CountingTail()
    let follow = makeFollow(tail)
    let sessions = (0...FollowConversation.parkedLimit).map { session("s\($0)") }
    for session in sessions {
      await tail.write(["user:hi"], to: file(session.name))
      _ = await self.follow(session, with: follow) { $0.entries.count == 1 }
    }
    #expect(await follow.parkedSessionIDs == sessions.dropFirst().map(\.id))
  }
}
