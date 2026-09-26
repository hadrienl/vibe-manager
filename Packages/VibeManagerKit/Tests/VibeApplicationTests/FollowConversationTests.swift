import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Lines of the form `user:<text>` or `agent:<text>`, one entry each.
private final class LineDecoder: ConversationDecoding {
  private(set) var entries: [ConversationEntry] = []
  private let file: String

  init(file: String) {
    self.file = file
  }

  func consume(_ line: Data) {
    let text = String(decoding: line, as: UTF8.self)
    let id = "\(file)#\(entries.count)"
    if text.hasPrefix("user:") {
      entries.append(
        ConversationEntry(id: id, content: .userPrompt(String(text.dropFirst(5)), attachments: 0)))
    } else if text.hasPrefix("agent:") {
      entries.append(ConversationEntry(id: id, content: .agentText(String(text.dropFirst(6)))))
    }
  }
}

private struct LineProvider: AgentProvider, AgentConversationReporting {
  let descriptor: AgentDescriptor
  let files: [URL]

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentDiagnosticFactoryStub.available(descriptor)
  }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw CancellationError()
  }
  func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession,
    hint: AgentActivityEvent?
  ) -> [URL] {
    files.filter { $0.lastPathComponent.hasPrefix(conversation.resumeIdentifier ?? "-") }
  }
  func conversationDecoder(for file: URL) -> any ConversationDecoding {
    LineDecoder(file: file.lastPathComponent)
  }
  var promptFormat: AgentPromptFormat { AgentPromptFormat() }
}

/// An agent that writes nothing readable.
private struct SilentProvider: AgentProvider {
  let descriptor: AgentDescriptor
  func availability(forceRefresh: Bool) async -> AgentAvailability {
    AgentDiagnosticFactoryStub.available(descriptor)
  }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    throw CancellationError()
  }
}

private enum AgentDiagnosticFactoryStub {
  static func available(_ descriptor: AgentDescriptor) -> AgentAvailability {
    AgentAvailability(
      state: .available, installation: nil,
      diagnostic: AgentDiagnostic(
        providerID: descriptor.id, providerName: descriptor.displayName, state: .available,
        summary: "", probedAt: Date(), remediations: []))
  }
}

private struct Registry: AgentProviderResolving {
  let providers: [any AgentProvider]
  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

/// A tail fed by the test, file by file.
private actor ScriptedTail: TranscriptTailing {
  private var contents: [URL: [String]] = [:]
  private var continuations: [URL: AsyncStream<TranscriptChunk>.Continuation] = [:]

  init(_ contents: [URL: [String]]) {
    self.contents = contents
  }

  nonisolated func follow(_ file: URL) -> AsyncStream<TranscriptChunk> {
    let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    Task { await self.opened(file, continuation) }
    return stream
  }

  private func opened(_ file: URL, _ continuation: AsyncStream<TranscriptChunk>.Continuation) {
    continuations[file] = continuation
    continuation.yield(.lines((contents[file] ?? []).map { Data($0.utf8) }))
  }

  func read(_ file: URL) async -> [Data] {
    (contents[file] ?? []).map { Data($0.utf8) }
  }

  func write(_ lines: [String], to file: URL) {
    continuations[file]?.yield(.lines(lines.map { Data($0.utf8) }))
  }

  func replace(_ file: URL, with lines: [String]) {
    continuations[file]?.yield(.reset)
    continuations[file]?.yield(.lines(lines.map { Data($0.utf8) }))
  }
}

private actor Store {
  var session: WorkSession
  init(_ session: WorkSession) { self.session = session }
  func set(_ session: WorkSession) { self.session = session }
}

@Suite("Following a session's conversation")
struct FollowConversationTests {
  private let alpha = AgentDescriptor(id: AgentProviderID("alpha"), displayName: "Alpha")
  private let beta = AgentDescriptor(id: AgentProviderID("beta"), displayName: "Beta")
  private let silent = AgentDescriptor(id: AgentProviderID("silent"), displayName: "Silent")

  private func next(
    _ iterator: inout AsyncStream<ConversationSnapshot>.Iterator,
    until condition: (ConversationSnapshot) -> Bool
  ) async -> ConversationSnapshot? {
    while let snapshot = await iterator.next() {
      if condition(snapshot) { return snapshot }
    }
    return nil
  }

  @Test("What is written already, then what is written next, then a file replaced")
  func live() async throws {
    let file = URL(fileURLWithPath: "/t/one.jsonl")
    let tail = ScriptedTail([file: ["user:hi", "agent:hello"]])
    let follow = FollowConversation(
      agents: Registry(providers: [LineProvider(descriptor: alpha, files: [file])]), tail: tail,
      refreshInterval: .milliseconds(100), publishInterval: .milliseconds(10))
    let session = WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: "one"))
    var iterator = await follow.follow(session).makeAsyncIterator()
    let first = await next(&iterator) { $0.availability == .available }
    #expect(
      first?.entries.map(\.content) == [.userPrompt("hi", attachments: 0), .agentText("hello")])
    await tail.write(["agent:more"], to: file)
    let second = await next(&iterator) { $0.entries.count == 3 }
    #expect(second?.entries.last?.content == .agentText("more"))
    await tail.replace(file, with: ["user:again"])
    let third = await next(&iterator) { $0.entries.count == 1 }
    #expect(third?.entries.first?.content == .userPrompt("again", attachments: 0))
  }

  @Test("An identifier the agent gives after the start is read from the store, then followed")
  func identifierArrivesLater() async throws {
    let file = URL(fileURLWithPath: "/t/late.jsonl")
    let tail = ScriptedTail([file: ["user:bonjour", "agent:salut"]])
    let id = SessionID()
    let pending = WorkSession(
      id: id, name: "S", agent: SessionAgentConfiguration(providerID: "alpha"))
    let known = WorkSession(
      id: id, name: "S",
      agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: "late"))
    let store = Store(pending)
    let follow = FollowConversation(
      agents: Registry(providers: [LineProvider(descriptor: alpha, files: [file])]), tail: tail,
      current: { _ in await store.session },
      refreshInterval: .milliseconds(50), publishInterval: .milliseconds(10))
    var iterator = await follow.follow(pending).makeAsyncIterator()
    let empty = await next(&iterator) { _ in true }
    #expect(empty?.availability == .notYetWritten(providerName: "Alpha"))
    await store.set(known)
    let found = await next(&iterator) { $0.entries.count == 2 }
    #expect(found?.entries.last?.content == .agentText("salut"))
  }

  @Test("After a switch of agent, both conversations, the second opened by a notice")
  func chapters() async throws {
    let one = URL(fileURLWithPath: "/t/one.jsonl")
    let two = URL(fileURLWithPath: "/t/two.jsonl")
    let tail = ScriptedTail([one: ["user:first"], two: ["user:second"]])
    let follow = FollowConversation(
      agents: Registry(providers: [
        LineProvider(descriptor: alpha, files: [one]), LineProvider(descriptor: beta, files: [two]),
      ]), tail: tail, refreshInterval: .milliseconds(100), publishInterval: .milliseconds(10))
    var session = WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: "one"))
    _ = try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "beta", resumeIdentifier: "two"),
      handover: .initialPrompt, at: Date())
    var iterator = await follow.follow(session, live: false).makeAsyncIterator()
    let snapshot = await next(&iterator) { $0.availability == .available }
    #expect(snapshot?.entries.count == 3)
    #expect(snapshot?.entries.first?.content == .userPrompt("first", attachments: 0))
    guard case .notice(.chapter(let name, _)) = snapshot?.entries[1].content else {
      Issue.record("no chapter")
      return
    }
    #expect(name == "Beta")
  }

  @Test("An agent that writes nothing readable, and one that has not written yet")
  func availability() async throws {
    let follow = FollowConversation(
      agents: Registry(providers: [
        SilentProvider(descriptor: silent), LineProvider(descriptor: alpha, files: []),
      ]), tail: ScriptedTail([:]), refreshInterval: .milliseconds(100),
      publishInterval: .milliseconds(10))
    var unsupported = await follow.follow(
      WorkSession(name: "S", agent: SessionAgentConfiguration(providerID: "silent"))
    ).makeAsyncIterator()
    #expect(await unsupported.next()?.availability == .unsupported(providerName: "Silent"))
    var shell = await follow.follow(WorkSession(name: "Shell")).makeAsyncIterator()
    #expect(await shell.next()?.availability == .noAgent)
    var empty = await follow.follow(
      WorkSession(
        name: "S", agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: "x")),
      live: false
    ).makeAsyncIterator()
    #expect(await empty.next()?.availability == .notYetWritten(providerName: "Alpha"))
  }
}
