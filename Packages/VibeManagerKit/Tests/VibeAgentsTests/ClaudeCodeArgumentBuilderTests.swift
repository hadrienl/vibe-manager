import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Claude Code argument building")
struct ClaudeCodeArgumentBuilderTests {
  private static let assigned = UUID(uuidString: "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04")!

  private func builder() -> ClaudeCodeArgumentBuilder {
    ClaudeCodeArgumentBuilder(makeIdentifier: { Self.assigned })
  }

  private func arguments(
    _ request: AgentLaunchRequest,
    delivery: PromptDelivery = .none
  ) throws -> [String] {
    try builder().arguments(
      for: request,
      promptDelivery: delivery,
      descriptor: ClaudeCodeAgentProvider.descriptor
    )
  }

  @Test("A fresh launch names the conversation it is about to create")
  func assignsSessionIdentifier() throws {
    let arguments = try arguments(AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app"))

    #expect(arguments == ["--session-id", Self.assigned.uuidString.lowercased()])
  }

  @Test("A model and a prompt sit after the identifier, the prompt behind a separator")
  func modelAndPrompt() throws {
    let arguments = try arguments(
      AgentLaunchRequest(
        workingDirectoryPath: "/Users/a/dev/app",
        modelID: "claude-opus-5",
        initialPrompt: "Corrige le test qui échoue"
      ),
      delivery: .argument
    )

    #expect(
      arguments == [
        "--session-id", Self.assigned.uuidString.lowercased(),
        "--model", "claude-opus-5",
        "--", "Corrige le test qui échoue",
      ]
    )
  }

  @Test("A difficult prompt stays one argument and never loses a character")
  func difficultPrompt() throws {
    let prompt = "--force $(rm -rf /) \"quoted\"\nsecond line\t😀"
    let arguments = try arguments(
      AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app", initialPrompt: prompt),
      delivery: .argument
    )

    #expect(arguments.last == prompt)
    // Without the separator the CLI reads a leading dash as an option and refuses to start.
    #expect(arguments[arguments.count - 2] == "--")
  }

  @Test("Resuming passes the stored identifier and never assigns a new one")
  func resume() throws {
    let identifier = "8C1D0B7E-1111-4222-8333-444455556666"
    let arguments = try arguments(
      AgentLaunchRequest(
        workingDirectoryPath: "/Users/a/dev/app",
        initialPrompt: "Reprends là où on s'est arrêtés",
        resume: .identifier(identifier)
      ),
      delivery: .argument
    )

    #expect(
      arguments == [
        "--resume", identifier.lowercased(),
        "--", "Reprends là où on s'est arrêtés",
      ]
    )
    // The CLI refuses both options together unless --fork-session is passed, and forking
    // would break the link the session just stored.
    #expect(!arguments.contains("--session-id"))
    #expect(!arguments.contains("--fork-session"))
  }

  @Test("Only a UUID is accepted as a resume identifier")
  func rejectsNonUUIDIdentifiers() {
    for identifier in ["--last", " ", "last", "3f2b6c1e-8a4d-4f7b-9c2e", "/tmp/session"] {
      #expect(throws: AgentLaunchError.missingResumeIdentifier) {
        try arguments(
          AgentLaunchRequest(
            workingDirectoryPath: "/Users/a/dev/app",
            resume: .identifier(identifier)
          )
        )
      }
    }
  }

  @Test("A malformed model slug is refused before a process is started")
  func rejectsMalformedModel() {
    for model in ["-x", "", "vendor/model", "two words", "line\nbreak"] {
      #expect(throws: AgentLaunchError.unsupportedModel(model)) {
        try arguments(
          AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app", modelID: model)
        )
      }
    }
  }

  @Test("A prompt that would go to the standard input is refused instead")
  func refusesStandardInput() {
    let prompt = String(repeating: "a", count: AgentPromptLimits.argumentByteLimit + 1)

    #expect(
      throws: AgentLaunchError.promptTooLarge(
        byteCount: prompt.utf8.count,
        limit: AgentPromptLimits.argumentByteLimit
      )
    ) {
      try arguments(
        AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app", initialPrompt: prompt),
        delivery: .standardInput(prompt)
      )
    }
  }

  @Test("The assigned identifier can be read back from the command line")
  func readsBackAssignedIdentifier() throws {
    let fresh = try arguments(AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app"))
    let resumed = try arguments(
      AgentLaunchRequest(
        workingDirectoryPath: "/Users/a/dev/app",
        resume: .identifier(Self.assigned.uuidString)
      )
    )

    #expect(
      ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: fresh)
        == Self.assigned.uuidString.lowercased()
    )
    #expect(ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: resumed) == nil)
    #expect(ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: ["--session-id"]) == nil)
    #expect(
      ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: ["--session-id", "not-a-uuid"])
        == nil
    )
  }

  @Test("Every launch of a new conversation gets its own identifier")
  func generatesDistinctIdentifiers() throws {
    let builder = ClaudeCodeArgumentBuilder()
    let request = AgentLaunchRequest(workingDirectoryPath: "/Users/a/dev/app")
    let first = try builder.arguments(
      for: request, promptDelivery: .none, descriptor: ClaudeCodeAgentProvider.descriptor)
    let second = try builder.arguments(
      for: request, promptDelivery: .none, descriptor: ClaudeCodeAgentProvider.descriptor)

    #expect(first != second)
    #expect(ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: first) != nil)
  }
}
