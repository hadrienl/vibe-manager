import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI
@testable import VibeUI

/// Lines of the form `user:<text>`, one entry each.
private final class PromptDecoder: ConversationDecoding {
  private(set) var entries: [ConversationEntry] = []
  private let file: String

  init(file: String) {
    self.file = file
  }

  func consume(_ record: TranscriptRecord) {
    guard let text = record.object["line"] as? String, text.hasPrefix("user:") else { return }
    entries.append(
      ConversationEntry(
        id: "\(file)#\(entries.count)",
        content: .userPrompt(String(text.dropFirst(5)), attachments: [])))
  }
}

private struct PromptProvider: AgentProvider, AgentConversationReporting {
  let descriptor: AgentDescriptor
  let files: [URL]

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
    files.filter { $0.lastPathComponent.hasPrefix(conversation.resumeIdentifier ?? "-") }
  }
  func conversationDecoder(for file: URL) -> any ConversationDecoding {
    PromptDecoder(file: file.lastPathComponent)
  }
  var promptFormat: AgentPromptFormat { AgentPromptFormat() }
}

private struct Providers: AgentProviderResolving {
  let providers: [any AgentProvider]
  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

/// Every file whole, then nothing more.
private struct WholeFiles: TranscriptTailing {
  let contents: [URL: [String]]

  func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<TranscriptChunk> {
    AsyncStream { continuation in
      continuation.yield(.records(records(of: file), isCaughtUp: true))
    }
  }

  func read(_ file: URL) async -> [TranscriptRecord] {
    records(of: file)
  }

  /// Each line as the record `{"line": …}`.
  private func records(of file: URL) -> [TranscriptRecord] {
    (contents[file] ?? []).compactMap { text in
      (try? JSONSerialization.data(withJSONObject: ["line": text])).flatMap(
        TranscriptRecord.init(line:))
    }
  }
}

@MainActor
@Suite("Following the sessions the workspace shows", .timeLimit(.minutes(1)))
struct ConversationWorkspaceFollowTests {
  @Test("A switch of agent heard while the follow is set up still reaches it (#255)")
  func changeBeforeTheFollowExists() async throws {
    let one = URL(fileURLWithPath: "/t/one.jsonl")
    let two = URL(fileURLWithPath: "/t/two.jsonl")
    let alpha = AgentDescriptor(id: AgentProviderID("alpha"), displayName: "Alpha")
    let beta = AgentDescriptor(id: AgentProviderID("beta"), displayName: "Beta")
    let follow = FollowConversation(
      agents: Providers(providers: [
        PromptProvider(descriptor: alpha, files: [one]),
        PromptProvider(descriptor: beta, files: [two]),
      ]), tail: WholeFiles(contents: [one: ["user:first"], two: ["user:second"]]),
      refreshInterval: .milliseconds(20), safetyInterval: .seconds(3600),
      publishInterval: .milliseconds(10))
    let workspace = ConversationWorkspace(follow: follow)
    var session = WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "alpha", resumeIdentifier: "one"))
    let model = workspace.show(session)
    // In the same turn of the main actor: the follow `show` asked for does not exist yet.
    _ = try session.switchAgent(
      to: SessionAgentConfiguration(providerID: "beta", resumeIdentifier: "two"),
      handover: .initialPrompt, at: Date())
    workspace.sessionsChanged([session])
    await waitUntil("the second conversation shown") {
      model.snapshot.entries.contains { $0.content == .userPrompt("second", attachments: []) }
    }
  }

  @Test("A turn that starts, or hooks heard for the first time, may bring a new transcript")
  func mayStartTranscript() {
    let working = AgentActivityState(activity: .working, source: .structured)
    let idle = AgentActivityState(activity: .idle, source: .structured)
    #expect(ConversationWorkspace.mayStartTranscript(from: idle, to: working))
    #expect(ConversationWorkspace.mayStartTranscript(from: nil, to: idle))
    #expect(!ConversationWorkspace.mayStartTranscript(from: working, to: working))
    #expect(!ConversationWorkspace.mayStartTranscript(from: working, to: idle))
    #expect(!ConversationWorkspace.mayStartTranscript(from: idle, to: nil))
  }
}
