import Foundation
import VibeApplication
import VibeProcess

/// What a theme asks of a CLI, and how its answer is read (#118).
public protocol ThemeCommand: Sendable {
  /// The arguments, given the folder the command runs in: files it needs are written there.
  func arguments(for request: ThemeGenerationRequest, in workspace: URL, models: [AgentModel])
    throws -> [String]
  var additionalEnvironment: [String: String] { get }
  /// What goes on the standard input.
  func input(for request: ThemeGenerationRequest) -> Data
  /// The answer, as the agent wrote it: checked by `GenerateConversationTheme`, not here.
  func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data
}

/// One theme: the agent's CLI with its own account, in a process without a terminal, run from an
/// empty temporary folder, without tools, MCP servers, hooks nor memory — what it answers is
/// data, held to the schema, and nothing it reads can reach a tool that acts.
public struct CommandLineThemeGenerator: ConversationThemeGenerating {
  /// A theme is 27 colours and a name, checked against 20 contrasts: well under a minute, with
  /// room for a slow account.
  public static let timeout: Duration = .seconds(120)

  private let provider: any AgentProvider
  private let command: any ThemeCommand
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, command: any ThemeCommand,
    runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.command = command
    self.runner = runner
  }

  public func generate(_ request: ThemeGenerationRequest) async throws -> Data {
    let run = OneShotAgentRun(
      provider: provider, runner: runner, folderPrefix: "VibeManager-theme-",
      timeout: Self.timeout)
    do {
      return try await run.run { workspace, models in
        OneShotAgentRun.Invocation(
          arguments: try command.arguments(for: request, in: workspace, models: models),
          environment: command.additionalEnvironment,
          input: command.input(for: request))
      } read: { result, workspace in
        guard !result.didTimeOut else { throw ThemeGenerationError.timedOut }
        return try command.answer(from: result, in: workspace)
      }
    } catch let failure as OneShotAgentRun.Failure {
      switch failure {
      case .unavailable(let state):
        throw ThemeGenerationError.unavailable(Self.unavailability(state))
      case .noWorkspace: throw ThemeGenerationError.failed("no temporary folder")
      case .noLaunchPlan: throw ThemeGenerationError.failed("no launch plan")
      case .couldNotStart: throw ThemeGenerationError.failed("could not start")
      }
    }
  }

  static func unavailability(_ state: AgentAvailabilityState)
    -> ThemeGenerationError.Unavailability
  {
    switch state {
    case .unauthenticated: .signedOut
    case .outdated: .outdated
    default: .missing
    }
  }

  static func failure(of result: BoundedProcessResult) -> ThemeGenerationError {
    switch CommandLineSummarizer.failure(of: result) {
    case .unavailable(.outdated): .unavailable(.outdated)
    case .unavailable(.signedOut): .unavailable(.signedOut)
    case .unavailable: .unavailable(.missing)
    case .failed(let reason): .failed(reason)
    }
  }
}

/// `claude -p`: no tools, no MCP, no hooks, no settings, no memory and no transcript left behind,
/// the theme's instructions as its system prompt, the answer held to the schema. Sonnet: 27
/// colours that go together, and contrasts computed rather than guessed.
public struct ClaudeCodeThemeCommand: ThemeCommand {
  public static let model = "sonnet"

  public init() {
    // Nothing to set: the command is the same for every theme.
  }

  public func arguments(
    for request: ThemeGenerationRequest, in _: URL, models _: [AgentModel]
  ) throws -> [String] {
    [
      "-p", "--model", Self.model, "--tools", "", "--strict-mcp-config",
      "--no-session-persistence", "--setting-sources", "",
      "--settings", #"{"disableAllHooks":true}"#,
      "--system-prompt", ThemeInstructions.systemPrompt(language: request.language),
      "--output-format", "json",
      "--json-schema", ConversationThemeSchema.forAgent(isDark: request.isDark),
    ]
  }

  public var additionalEnvironment: [String: String] { ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"] }

  public func input(for request: ThemeGenerationRequest) -> Data {
    Data(ThemeInstructions.input(for: request).utf8)
  }

  public func answer(from result: BoundedProcessResult, in _: URL) throws -> Data {
    let answer = (try? JSONSerialization.jsonObject(with: result.standardOutput)) as? [String: Any]
    guard result.exitCode == 0, let answer, answer["is_error"] as? Bool != true else {
      throw CommandLineThemeGenerator.failure(of: result)
    }
    guard let structured = answer["structured_output"],
      JSONSerialization.isValidJSONObject(structured),
      let data = try? JSONSerialization.data(withJSONObject: structured)
    else { throw ThemeGenerationError.failed("no structured output") }
    return data
  }
}

/// `codex exec`: ephemeral, read only, outside any repository and without the user's
/// configuration, its last message written to a file and held to the schema. Codex takes no
/// system prompt: the instructions lead the input. The account's own model.
public struct CodexThemeCommand: ThemeCommand {
  static let schemaFile = "schema.json"
  static let answerFile = "answer.json"

  public init() {
    // Nothing to set: the command is the same for every theme.
  }

  public func arguments(
    for request: ThemeGenerationRequest, in workspace: URL, models _: [AgentModel]
  ) throws -> [String] {
    let schema = workspace.appendingPathComponent(Self.schemaFile)
    do {
      try Data(ConversationThemeSchema.forAgent(isDark: request.isDark).utf8).write(to: schema)
    } catch {
      throw ThemeGenerationError.failed("no schema file")
    }
    return [
      "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
      "-s", "read-only",
      "--disable", "hooks", "--disable", "apps", "--disable", "plugins",
      "-c", "mcp_servers={}", "-c", "tools.web_search=false",
      "--output-schema", schema.path, "-o", workspace.appendingPathComponent(Self.answerFile).path,
      "-",
    ]
  }

  public var additionalEnvironment: [String: String] { [:] }

  public func input(for request: ThemeGenerationRequest) -> Data {
    Data(
      (ThemeInstructions.systemPrompt(language: request.language) + "\n\n"
        + ThemeInstructions.input(for: request)).utf8)
  }

  public func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data {
    guard result.exitCode == 0 else { throw CommandLineThemeGenerator.failure(of: result) }
    let url = workspace.appendingPathComponent(Self.answerFile)
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw ThemeGenerationError.failed("no answer")
    }
    defer { try? handle.close() }
    // Never more than a theme may weigh, and one more byte to tell.
    let data = (try? handle.read(upToCount: ConversationThemeFile.maximumSize + 1)) ?? Data()
    guard !data.isEmpty else { throw ThemeGenerationError.failed("no answer") }
    return data
  }
}

/// A theme of its own, at once: the application's scenarios and a copy without any agent. With
/// `VIBE_MOCK_THEME=fail`, a failure; `illegible`, an answer that is always refused.
public struct MockThemeGenerator: ConversationThemeGenerating {
  private let behaviour: String?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    behaviour = environment["VIBE_MOCK_THEME"]
  }

  public func generate(_ request: ThemeGenerationRequest) async throws -> Data {
    if behaviour == "fail" { throw ThemeGenerationError.failed("mock") }
    var theme = request.current ?? (request.isDark ? .night : .paper)
    if behaviour == "illegible" { theme.text = theme.background }
    theme.personalName = theme.personalName ?? (request.isDark ? "Mock Night" : "Mock Paper")
    let base = request.isDark ? ConversationTheme.night : .paper
    // Each pass changes something that can be seen: the accent goes back and forth.
    if theme.accent == base.accent {
      theme.accent = request.isDark ? "#F2B544" : "#1A7A3F"
    } else {
      theme.accent = base.accent
    }
    return ConversationThemeFile.encode(theme)
  }
}

extension ClaudeCodeAgentProvider: ConversationThemeGeneratingProviding {
  public func themeGenerator() -> any ConversationThemeGenerating {
    CommandLineThemeGenerator(provider: self, command: ClaudeCodeThemeCommand())
  }
}

extension CodexAgentProvider: ConversationThemeGeneratingProviding {
  public func themeGenerator() -> any ConversationThemeGenerating {
    CommandLineThemeGenerator(provider: self, command: CodexThemeCommand())
  }
}

extension MockAgentProvider: ConversationThemeGeneratingProviding {
  public func themeGenerator() -> any ConversationThemeGenerating {
    MockThemeGenerator(environment: environment)
  }
}
