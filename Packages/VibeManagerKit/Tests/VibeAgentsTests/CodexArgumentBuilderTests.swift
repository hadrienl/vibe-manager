import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Codex command construction")
struct CodexArgumentBuilderTests {
  private let builder = CodexArgumentBuilder()
  private let descriptor = CodexAgentProvider.descriptor

  private func arguments(
    workingDirectoryPath: String = "/Users/test/Projects/app",
    modelID: String? = nil,
    initialPrompt: String? = nil,
    resume: AgentResumeRequest = .none
  ) throws -> [String] {
    let request = AgentLaunchRequest(
      workingDirectoryPath: workingDirectoryPath,
      modelID: modelID,
      initialPrompt: initialPrompt,
      resume: resume
    )
    let delivery = try AgentLaunchValidation.promptDelivery(
      for: request.initialPrompt,
      descriptor: descriptor
    )
    return try builder.arguments(for: request, promptDelivery: delivery, descriptor: descriptor)
  }

  @Test("A bare launch only states the working directory")
  func bareLaunch() throws {
    #expect(try arguments() == ["-C", "/Users/test/Projects/app"])
  }

  @Test("No model means no -m, so the CLI keeps the user's configured model")
  func withoutModel() throws {
    let arguments = try arguments(initialPrompt: "Fix the failing test")
    #expect(arguments == ["-C", "/Users/test/Projects/app", "--", "Fix the failing test"])
  }

  @Test("A full launch passes the model, the directory and the prompt")
  func fullLaunch() throws {
    let arguments = try arguments(modelID: "gpt-6-astra", initialPrompt: "Fix the failing test")
    #expect(
      arguments == [
        "-m", "gpt-6-astra", "-C", "/Users/test/Projects/app", "--", "Fix the failing test",
      ]
    )
  }

  @Test("Resuming names the session, never the picker and never --last")
  func resumeLaunch() throws {
    let arguments = try arguments(
      initialPrompt: "Carry on",
      resume: .identifier("019ee0a1-06d9-7e52-957b-d61a982d6b43")
    )
    #expect(
      arguments == [
        "resume", "-C", "/Users/test/Projects/app", "--",
        "019ee0a1-06d9-7e52-957b-d61a982d6b43", "Carry on",
      ]
    )
    #expect(!arguments.contains("--last"))
  }

  @Test("The subcommand comes before its options")
  func resumeSubcommandComesFirst() throws {
    let arguments = try arguments(
      modelID: "gpt-6-astra",
      resume: .identifier("019ee0a1-06d9-7e52-957b-d61a982d6b43")
    )
    #expect(arguments.first == "resume")
  }

  @Test(
    "Difficult prompts stay a single argument",
    arguments: [
      "Rewrite \"the\" parser",
      "It's a $(rm -rf /) prompt",
      "Ligne une\nligne deux",
      "--help",
      "-p",
      "Refactorise le café ☕️ en prenant son temps",
      "Backtick `whoami` and pipe | and semicolon ;",
    ]
  )
  func difficultPrompts(prompt: String) throws {
    let arguments = try arguments(initialPrompt: prompt)
    #expect(arguments.last == prompt)
    // Whatever the prompt looks like, it cannot be read as an option.
    #expect(arguments[arguments.count - 2] == "--")
  }

  @Test("Difficult working directories stay a single argument")
  func difficultWorkingDirectory() throws {
    let path = "/Users/test/Mes projets/app — v2"
    #expect(try arguments(workingDirectoryPath: path) == ["-C", path])
  }

  @Test("A prompt too large for argv is refused instead of typed into the composer")
  func oversizedPromptIsRefused() {
    let prompt = String(repeating: "a", count: AgentPromptLimits.argumentByteLimit + 1)
    #expect(throws: AgentLaunchError.self) {
      try arguments(initialPrompt: prompt)
    }
  }

  @Test("A prompt at the argv limit is still passed as an argument")
  func promptAtLimit() throws {
    let prompt = String(repeating: "a", count: AgentPromptLimits.argumentByteLimit)
    #expect(try arguments(initialPrompt: prompt).last == prompt)
  }

  @Test(
    "A malformed model slug is refused",
    arguments: ["", " ", "-m", "gpt 6", "gpt\n6", "openai/gpt-6"]
  )
  func malformedModel(modelID: String) {
    #expect(throws: AgentLaunchError.self) {
      try arguments(modelID: modelID)
    }
  }

  @Test("A known slug that no catalog lists is accepted")
  func unknownModelIsAccepted() throws {
    #expect(try arguments(modelID: "gpt-42-unreleased").contains("gpt-42-unreleased"))
  }

  @Test(
    "A malformed resume identifier is refused",
    arguments: ["", "   ", "-x", "../escape", "a/b", "id with space"]
  )
  func malformedResumeIdentifier(identifier: String) {
    #expect(throws: AgentLaunchError.self) {
      try arguments(resume: .identifier(identifier))
    }
  }

  @Test("A session name is a valid resume identifier")
  func sessionNameResume() throws {
    #expect(try arguments(resume: .identifier("refonte-parser")).contains("refonte-parser"))
  }

  @Test("Standard input delivery is never produced for an interactive terminal")
  func neverDeliversOnStandardInput() {
    let request = AgentLaunchRequest(workingDirectoryPath: "/Users/test", initialPrompt: "hello")
    #expect(throws: AgentLaunchError.self) {
      try builder.arguments(
        for: request,
        promptDelivery: .standardInput("hello"),
        descriptor: descriptor
      )
    }
  }
}
