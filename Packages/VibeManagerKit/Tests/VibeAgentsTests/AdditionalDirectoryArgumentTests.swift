import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// The golden command lines of a session spread over several repositories.
@Suite("Handing the other repositories of a session to the agent")
struct AdditionalDirectoryArgumentTests {
  private static let assigned = UUID(uuidString: "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04")!

  private let request = AgentLaunchRequest(
    workingDirectoryPath: "/Users/a/VibeManager/Worktrees/refonte/api",
    modelID: "fast",
    initialPrompt: "Vibe Manager runs this session…",
    additionalWorkingDirectoryPaths: [
      "/Users/a/VibeManager/Worktrees/refonte/web",
      "/Users/a/Mes Projets/l'API (v2)",
    ]
  )

  @Test("Claude Code gets one --add-dir per repository, ahead of the prompt's separator")
  func claudeCode() throws {
    let arguments = try ClaudeCodeArgumentBuilder(makeIdentifier: { Self.assigned }).arguments(
      for: request,
      promptDelivery: .argument,
      descriptor: ClaudeCodeAgentProvider.descriptor
    )

    #expect(
      arguments == [
        "--session-id", Self.assigned.uuidString.lowercased(),
        "--model", "fast",
        "--add-dir", "/Users/a/VibeManager/Worktrees/refonte/web",
        "--add-dir", "/Users/a/Mes Projets/l'API (v2)",
        "--", "Vibe Manager runs this session…",
      ]
    )
  }

  @Test("Codex gets the same --add-dir, after its workspace root")
  func codex() throws {
    let arguments = try CodexArgumentBuilder().arguments(
      for: request,
      promptDelivery: .argument,
      descriptor: CodexAgentProvider.descriptor
    )

    #expect(
      arguments == [
        "-m", "fast",
        "-C", "/Users/a/VibeManager/Worktrees/refonte/api",
        "--add-dir", "/Users/a/VibeManager/Worktrees/refonte/web",
        "--add-dir", "/Users/a/Mes Projets/l'API (v2)",
        "--", "Vibe Manager runs this session…",
      ]
    )
  }

  @Test("A resumed Codex conversation keeps its folders too")
  func codexResume() throws {
    var resumed = request
    resumed.initialPrompt = nil
    resumed.resume = .identifier("thread-1")
    let arguments = try CodexArgumentBuilder().arguments(
      for: resumed,
      promptDelivery: .none,
      descriptor: CodexAgentProvider.descriptor
    )

    #expect(arguments.first == "resume")
    #expect(arguments.filter { $0 == "--add-dir" }.count == 2)
    #expect(arguments.suffix(2) == ["--", "thread-1"])
  }

  @Test("Both providers say they can take them")
  func capabilities() {
    #expect(ClaudeCodeAgentProvider.descriptor.capabilities.supportsAdditionalDirectories)
    #expect(CodexAgentProvider.descriptor.capabilities.supportsAdditionalDirectories)
  }

  @Test("A provider that cannot take them leaves them out rather than pretending")
  func unsupportedProviderLeavesThemOut() throws {
    let descriptor = AgentDescriptor(
      id: AgentProviderID("plain"),
      displayName: "Plain",
      capabilities: AgentCapabilities(supportsInitialPrompt: true)
    )
    let arguments = try CodexArgumentBuilder().arguments(
      for: request,
      promptDelivery: .none,
      descriptor: descriptor
    )

    #expect(!arguments.contains("--add-dir"))
  }

  @Test("A relative folder is refused before anything is started")
  func relativeFolderIsRefused() {
    var relative = request
    relative.additionalWorkingDirectoryPaths = ["web"]

    #expect(throws: AgentLaunchError.invalidWorkingDirectory) {
      try CodexArgumentBuilder().arguments(
        for: relative,
        promptDelivery: .none,
        descriptor: CodexAgentProvider.descriptor
      )
    }
  }
}
