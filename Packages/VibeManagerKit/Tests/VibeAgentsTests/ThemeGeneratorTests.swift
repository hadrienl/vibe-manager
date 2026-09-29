import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeAgents

/// Runs nothing: records the request, writes `answer.json` in the folder as Codex would, and
/// prints `standardOutput` as Claude Code would.
private final class ThemeRunner: SummaryProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [BoundedProcessRequest] = []
  let termination: BoundedProcessResult.Termination
  let standardOutput: Data
  let standardError: String
  let answerFile: Data?

  init(
    termination: BoundedProcessResult.Termination = .exited(0), standardOutput: Data = Data(),
    standardError: String = "", answerFile: Data? = nil
  ) {
    self.termination = termination
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.answerFile = answerFile
  }

  var requests: [BoundedProcessRequest] { lock.withLock { recorded } }

  func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    lock.withLock { recorded.append(request) }
    let folder = URL(fileURLWithPath: try #require(request.workingDirectoryPath))
    if let answerFile { try answerFile.write(to: folder.appendingPathComponent("answer.json")) }
    return BoundedProcessResult(
      termination: termination, standardOutput: standardOutput,
      standardError: Data(standardError.utf8), outputTruncated: false)
  }
}

private let request = ThemeGenerationRequest(
  description: "une forêt la nuit", isDark: true, language: "fr-FR")

@Suite("Themes drawn by Claude Code (#118)")
struct ClaudeCodeThemeCommandTests {
  @Test("Without tools, MCP, hooks, settings nor memory, held to the schema")
  func arguments() throws {
    let arguments = try ClaudeCodeThemeCommand().arguments(
      for: request, in: URL(fileURLWithPath: "/tmp"), models: [])
    #expect(arguments.starts(with: ["-p", "--model", "sonnet", "--tools", ""]))
    for flag in ["--strict-mcp-config", "--no-session-persistence"] {
      #expect(arguments.contains(flag))
    }
    #expect(arguments.contains(#"{"disableAllHooks":true}"#))
    let schema = try #require(arguments.firstIndex(of: "--json-schema")).advanced(by: 1)
    #expect(arguments[schema] == ConversationThemeSchema.forAgent(isDark: true))
    let prompt = try #require(arguments.firstIndex(of: "--system-prompt")).advanced(by: 1)
    #expect(arguments[prompt].contains("fr-FR"))
    // The description goes on the standard input, never in the arguments.
    #expect(!arguments.joined().contains("une forêt"))
    #expect(
      ClaudeCodeThemeCommand().additionalEnvironment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1")
  }

  @Test("The structured output is the answer")
  func answer() async throws {
    let theme = ConversationThemeFile.encode(.night)
    let output = try JSONSerialization.data(withJSONObject: [
      "is_error": false,
      "structured_output": try JSONSerialization.jsonObject(with: theme),
    ])
    let runner = ThemeRunner(standardOutput: output)
    let generator = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeThemeCommand(),
      runner: runner)
    let answer = try await generator.generate(request)
    #expect(
      try ConversationThemeFile.decode(answer, id: "personal-x").colors
        == ConversationTheme.night.colors)
    let sent = try #require(runner.requests.first)
    let input = String(decoding: sent.standardInput?.data ?? Data(), as: UTF8.self)
    #expect(input.contains("une forêt"))
  }

  @Test("A CLI signed out says so; one that answers nothing fails")
  func failures() async {
    let signedOut = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeThemeCommand(),
      runner: ThemeRunner(termination: .exited(1), standardError: "Please run /login"))
    await #expect(throws: ThemeGenerationError.unavailable(.signedOut)) {
      try await signedOut.generate(request)
    }
    let empty = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: ClaudeCodeThemeCommand(),
      runner: ThemeRunner(standardOutput: Data(#"{"is_error":false}"#.utf8)))
    await #expect(throws: ThemeGenerationError.failed("no structured output")) {
      try await empty.generate(request)
    }
  }
}

@Suite("Themes drawn by Codex (#118)")
struct CodexThemeCommandTests {
  @Test("Ephemeral, read only, without the user's configuration, held to a schema file")
  func arguments() async throws {
    let runner = ThemeRunner(answerFile: ConversationThemeFile.encode(.night))
    let generator = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: CodexThemeCommand(), runner: runner)
    _ = try await generator.generate(request)
    let sent = try #require(runner.requests.first)
    let arguments = sent.arguments
    #expect(arguments.starts(with: ["exec", "--ephemeral", "--skip-git-repo-check"]))
    for flag in ["--ignore-user-config", "--ignore-rules", "--output-schema", "-o"] {
      #expect(arguments.contains(flag))
    }
    let sandbox = try #require(arguments.firstIndex(of: "-s")).advanced(by: 1)
    #expect(arguments[sandbox] == "read-only")
    for feature in ["hooks", "apps", "plugins"] { #expect(arguments.contains(feature)) }
    #expect(arguments.contains("mcp_servers={}"))
    #expect(arguments.contains("tools.web_search=false"))
    #expect(!arguments.contains("-m"))
    #expect(arguments.last == "-")
    let input = String(decoding: sent.standardInput?.data ?? Data(), as: UTF8.self)
    #expect(input.hasPrefix("You design colour themes"))
    #expect(input.contains("<description>\nune forêt la nuit\n</description>"))
  }

  @Test("No answer written is a failure; an answer too large is cut, then refused by the check")
  func answers() async throws {
    let none = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: CodexThemeCommand(),
      runner: ThemeRunner())
    await #expect(throws: ThemeGenerationError.failed("no answer")) {
      try await none.generate(request)
    }
    let huge = Data(repeating: 0x20, count: ConversationThemeFile.maximumSize * 3)
    let large = CommandLineThemeGenerator(
      provider: MockAgentProvider(environment: [:]), command: CodexThemeCommand(),
      runner: ThemeRunner(answerFile: huge))
    let answer = try await large.generate(request)
    #expect(answer.count == ConversationThemeFile.maximumSize + 1)
  }

  @Test("An agent that is not installed cannot draw")
  func unavailable() async {
    let generator = CommandLineThemeGenerator(
      provider: MockAgentProvider(simulatedState: .notFound, environment: [:]),
      command: CodexThemeCommand(), runner: ThemeRunner())
    await #expect(throws: ThemeGenerationError.unavailable(.missing)) {
      try await generator.generate(request)
    }
  }
}

@Suite("Which agents draw themes (#118)")
struct ThemeGeneratorOptionsTests {
  @Test("Claude Code and Codex draw themes; only those available are offered")
  func options() async {
    let claude: any AgentProvider = ClaudeCodeAgentProvider.make(environment: [:])
    let codex: any AgentProvider = CodexAgentProvider.make(environment: [:])
    #expect(claude is any ConversationThemeGeneratingProviding)
    #expect(codex is any ConversationThemeGeneratingProviding)
    let registry = AgentProviderRegistry(providers: [
      MockAgentProvider(environment: [:])
    ])
    let options = await AgentThemeGenerators(agents: registry).options()
    #expect(options.map(\.id) == [MockAgentProvider.id])
    let missing = AgentProviderRegistry(providers: [
      MockAgentProvider(simulatedState: .notFound, environment: [:])
    ])
    #expect(await AgentThemeGenerators(agents: missing).options().isEmpty)
  }

  @Test("The mock agent draws a legible theme, and changes the one it is given")
  func mock() async throws {
    let generate = GenerateConversationTheme(generator: MockThemeGenerator(environment: [:]))
    let first = try await generate(request)
    #expect(first.isDark)
    let second = try await generate(
      ThemeGenerationRequest(
        description: "plus chaud", isDark: true, language: "fr", current: first))
    #expect(second.id == first.id)
    #expect(second.accent != first.accent)
    await #expect(throws: ThemeGenerationError.self) {
      try await GenerateConversationTheme(
        generator: MockThemeGenerator(environment: ["VIBE_MOCK_THEME": "illegible"]))(request)
    }
  }
}

/// The real agents, signed in, over the network: opt in with `VIBE_THEME_INTEGRATION=1`.
@Suite(
  "A theme drawn by the real agents",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_THEME_INTEGRATION"] == "1"))
struct ThemeIntegrationTests {
  @Test("Claude Code draws a legible dark theme")
  func claude() async throws {
    let theme = try await GenerateConversationTheme(
      generator: ClaudeCodeAgentProvider.make().themeGenerator())(request)
    #expect(theme.isDark)
    #expect(theme.legibilityFailures.isEmpty)
  }

  @Test("Codex draws a legible dark theme")
  func codex() async throws {
    let theme = try await GenerateConversationTheme(
      generator: CodexAgentProvider.make().themeGenerator())(request)
    #expect(theme.isDark)
    #expect(theme.legibilityFailures.isEmpty)
  }
}
