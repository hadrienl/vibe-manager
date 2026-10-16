import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeAgents

/// Runs nothing: records the request, writes `answer.json` in the folder as Codex would, and
/// prints `standardOutput` as Claude Code would.
private final class SoundRunner: SummaryProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [BoundedProcessRequest] = []
  let standardOutput: Data
  let answerFile: Data?
  let termination: BoundedProcessResult.Termination

  init(
    termination: BoundedProcessResult.Termination = .exited(0), standardOutput: Data = Data(),
    answerFile: Data? = nil
  ) {
    self.termination = termination
    self.standardOutput = standardOutput
    self.answerFile = answerFile
  }

  var requests: [BoundedProcessRequest] { lock.withLock { recorded } }

  func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    lock.withLock { recorded.append(request) }
    let folder = URL(fileURLWithPath: try #require(request.workingDirectoryPath))
    if let answerFile { try answerFile.write(to: folder.appendingPathComponent("answer.json")) }
    return BoundedProcessResult(
      termination: termination, standardOutput: standardOutput, standardError: Data(),
      outputTruncated: false)
  }
}

private let request = AlertSoundGenerationRequest(
  description: "un petit carillon doux", language: "fr-FR")

@Suite("Sounds composed by Claude Code (#393)")
struct ClaudeCodeAlertSoundCommandTests {
  @Test("Without tools, MCP, hooks, settings nor memory, held to the schema")
  func arguments() throws {
    let arguments = try ClaudeCodeAlertSoundCommand().arguments(
      for: request, in: URL(fileURLWithPath: "/tmp"))
    #expect(arguments.starts(with: ["-p", "--model", "sonnet", "--tools", ""]))
    for flag in ["--strict-mcp-config", "--no-session-persistence"] {
      #expect(arguments.contains(flag))
    }
    #expect(arguments.contains(#"{"disableAllHooks":true}"#))
    let schema = try #require(arguments.firstIndex(of: "--json-schema")).advanced(by: 1)
    #expect(arguments[schema] == AlertSoundSchema.forAgent())
    let prompt = try #require(arguments.firstIndex(of: "--system-prompt")).advanced(by: 1)
    #expect(arguments[prompt].contains("fr-FR"))
    #expect(!arguments.joined().contains("carillon"))
    #expect(
      ClaudeCodeAlertSoundCommand().additionalEnvironment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1")
  }

  @Test("The structured output is the answer; the description goes on the standard input")
  func answer() async throws {
    let recipe = BundledAlertSound.chime.recipe
    let output = try JSONSerialization.data(withJSONObject: [
      "is_error": false,
      "structured_output": try JSONSerialization.jsonObject(with: recipe.encoded()),
    ])
    let runner = SoundRunner(standardOutput: output)
    let generator = CommandLineAlertSoundGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeAlertSoundCommand(),
      runner: runner)
    let answer = try await generator.generate(request)
    #expect(try AlertSoundRecipe.decode(answer).get() == recipe)
    let sent = try #require(runner.requests.first)
    let input = String(decoding: sent.standardInput?.data ?? Data(), as: UTF8.self)
    #expect(input.contains("<description>\nun petit carillon doux\n</description>"))
  }

  @Test("An error of the agent is a failure, not an answer")
  func failure() async {
    let output = Data(#"{"is_error":true,"result":"boom"}"#.utf8)
    let generator = CommandLineAlertSoundGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeAlertSoundCommand(),
      runner: SoundRunner(standardOutput: output))
    await #expect(throws: AlertSoundGenerationError.self) {
      try await generator.generate(request)
    }
  }
}

@Suite("Sounds composed by Codex (#393)")
struct CodexAlertSoundCommandTests {
  @Test("Ephemeral, read only, without the user's configuration, the schema in a file")
  func arguments() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexSound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let arguments = try CodexAlertSoundCommand().arguments(for: request, in: folder)
    #expect(arguments.starts(with: ["exec", "--ephemeral", "--skip-git-repo-check"]))
    #expect(arguments.contains("--ignore-user-config"))
    #expect(arguments.last == "-")
    let schema = folder.appendingPathComponent("schema.json")
    #expect(try String(contentsOf: schema, encoding: .utf8) == AlertSoundSchema.forAgent())
    let input = String(decoding: CodexAlertSoundCommand().input(for: request), as: UTF8.self)
    #expect(input.hasPrefix(AlertSoundInstructions.systemPrompt(language: "fr-FR")))
  }

  @Test("The last message written to its file is the answer")
  func answer() async throws {
    let recipe = BundledAlertSound.drop.recipe
    let generator = CommandLineAlertSoundGenerator(
      provider: MockAgentProvider(environment: [:]), command: CodexAlertSoundCommand(),
      runner: SoundRunner(answerFile: recipe.encoded()))
    #expect(try AlertSoundRecipe.decode(try await generator.generate(request)).get() == recipe)
  }
}

@Suite("The mock agent's sounds (#393)")
struct MockAlertSoundGeneratorTests {
  @Test("A playable sound, changed at each pass; failing or refused when asked")
  func mock() async throws {
    let first = try AlertSoundRecipe.decode(
      try await MockAlertSoundGenerator(environment: [:]).generate(request)
    ).get()
    let changed = try AlertSoundRecipe.decode(
      try await MockAlertSoundGenerator(environment: [:]).generate(
        AlertSoundGenerationRequest(description: "plus aigu", language: "fr", current: first))
    ).get()
    #expect(changed.voices[0].notes[0].pitch != first.voices[0].notes[0].pitch)
    await #expect(throws: AlertSoundGenerationError.failed("mock")) {
      try await MockAlertSoundGenerator(environment: ["VIBE_MOCK_SOUND": "fail"]).generate(request)
    }
    let invalid = try await MockAlertSoundGenerator(environment: ["VIBE_MOCK_SOUND": "invalid"])
      .generate(request)
    #expect(AlertSoundRecipe.decode(invalid) == .failure(.invalid(["voices is empty"])))
  }
}
