import Foundation
import VibeApplication
import VibeProcess

/// What a sound asks of a CLI, and how its answer is read (#393): the themes' commands (#118),
/// with the sound's instructions and schema.
public protocol AlertSoundCommand: Sendable {
  func arguments(for request: AlertSoundGenerationRequest, in workspace: URL) throws -> [String]
  var additionalEnvironment: [String: String] { get }
  func input(for request: AlertSoundGenerationRequest) -> Data
  /// The answer, as the agent wrote it: checked by `GenerateAlertSound`, not here.
  func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data
}

/// One sound: the agent's CLI with its own account, in a process without a terminal, run from an
/// empty temporary folder, without tools, MCP servers, hooks nor memory — what it answers is data,
/// held to the schema, and played by the application's synthesizer.
public struct CommandLineAlertSoundGenerator: AlertSoundGenerating {
  /// A recipe is a few notes: well under a minute, with room for a slow account.
  public static let timeout: Duration = .seconds(120)

  private let provider: any AgentProvider
  private let command: any AlertSoundCommand
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, command: any AlertSoundCommand,
    runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.command = command
    self.runner = runner
  }

  public func generate(_ request: AlertSoundGenerationRequest) async throws -> Data {
    let run = OneShotAgentRun(
      provider: provider, runner: runner, folderPrefix: "VibeManager-sound-",
      timeout: Self.timeout)
    do {
      return try await run.run { workspace, _ in
        OneShotAgentRun.Invocation(
          arguments: try command.arguments(for: request, in: workspace),
          environment: command.additionalEnvironment,
          input: command.input(for: request))
      } read: { result, workspace in
        guard !result.didTimeOut else { throw AlertSoundGenerationError.timedOut }
        return try command.answer(from: result, in: workspace)
      }
    } catch let failure as OneShotAgentRun.Failure {
      switch failure {
      case .unavailable(let state):
        throw AlertSoundGenerationError.unavailable(Self.unavailability(state))
      case .noWorkspace: throw AlertSoundGenerationError.failed("no temporary folder")
      case .noLaunchPlan: throw AlertSoundGenerationError.failed("no launch plan")
      case .couldNotStart: throw AlertSoundGenerationError.failed("could not start")
      }
    }
  }

  static func unavailability(_ state: AgentAvailabilityState)
    -> AlertSoundGenerationError.Unavailability
  {
    switch state {
    case .unauthenticated: .signedOut
    case .outdated: .outdated
    default: .missing
    }
  }

  static func failure(of result: BoundedProcessResult) -> AlertSoundGenerationError {
    switch CommandLineSummarizer.failure(of: result) {
    case .unavailable(.outdated): .unavailable(.outdated)
    case .unavailable(.signedOut): .unavailable(.signedOut)
    case .unavailable: .unavailable(.missing)
    case .failed(let reason): .failed(reason)
    }
  }
}

/// `claude -p` as for a theme: no tools, no MCP, no hooks, no settings, no memory, the sound's
/// instructions as its system prompt, the answer held to the schema. Sonnet: a few notes that go
/// together.
public struct ClaudeCodeAlertSoundCommand: AlertSoundCommand {
  public static let model = "sonnet"

  public init() {
    // Nothing to set: the command is the same for every sound.
  }

  public func arguments(for request: AlertSoundGenerationRequest, in _: URL) throws -> [String] {
    [
      "-p", "--model", Self.model, "--tools", "", "--strict-mcp-config",
      "--no-session-persistence", "--setting-sources", "",
      "--settings", #"{"disableAllHooks":true}"#,
      "--system-prompt", AlertSoundInstructions.systemPrompt(language: request.language),
      "--output-format", "json",
      "--json-schema", AlertSoundSchema.forAgent(),
    ]
  }

  public var additionalEnvironment: [String: String] { ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"] }

  public func input(for request: AlertSoundGenerationRequest) -> Data {
    Data(AlertSoundInstructions.input(for: request).utf8)
  }

  public func answer(from result: BoundedProcessResult, in _: URL) throws -> Data {
    let answer = (try? JSONSerialization.jsonObject(with: result.standardOutput)) as? [String: Any]
    guard result.exitCode == 0, let answer, answer["is_error"] as? Bool != true else {
      throw CommandLineAlertSoundGenerator.failure(of: result)
    }
    guard let structured = answer["structured_output"],
      JSONSerialization.isValidJSONObject(structured),
      let data = try? JSONSerialization.data(withJSONObject: structured)
    else { throw AlertSoundGenerationError.failed("no structured output") }
    return data
  }
}

/// `codex exec` as for a theme: ephemeral, read only, outside any repository and without the
/// user's configuration, its last message written to a file and held to the schema. The
/// instructions lead the input.
public struct CodexAlertSoundCommand: AlertSoundCommand {
  static let schemaFile = "schema.json"
  static let answerFile = "answer.json"

  public init() {
    // Nothing to set: the command is the same for every sound.
  }

  public func arguments(for request: AlertSoundGenerationRequest, in workspace: URL) throws
    -> [String]
  {
    let schema = workspace.appendingPathComponent(Self.schemaFile)
    do {
      try Data(AlertSoundSchema.forAgent().utf8).write(to: schema)
    } catch {
      throw AlertSoundGenerationError.failed("no schema file")
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

  public func input(for request: AlertSoundGenerationRequest) -> Data {
    Data(
      (AlertSoundInstructions.systemPrompt(language: request.language) + "\n\n"
        + AlertSoundInstructions.input(for: request)).utf8)
  }

  public func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data {
    guard result.exitCode == 0 else { throw CommandLineAlertSoundGenerator.failure(of: result) }
    let url = workspace.appendingPathComponent(Self.answerFile)
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw AlertSoundGenerationError.failed("no answer")
    }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: AlertSoundRecipe.maximumSize + 1)) ?? Data()
    guard !data.isEmpty else { throw AlertSoundGenerationError.failed("no answer") }
    return data
  }
}

/// A sound of its own, at once: the application's scenarios and a copy without any agent. With
/// `VIBE_MOCK_SOUND=fail`, a failure; `invalid`, an answer that is always refused.
public struct MockAlertSoundGenerator: AlertSoundGenerating {
  private let behaviour: String?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    behaviour = environment["VIBE_MOCK_SOUND"]
  }

  public func generate(_ request: AlertSoundGenerationRequest) async throws -> Data {
    if behaviour == "fail" { throw AlertSoundGenerationError.failed("mock") }
    var recipe = request.current ?? BundledAlertSound.chime.recipe
    if request.current == nil { recipe.name = "Mock Chime" }
    if behaviour == "invalid" { recipe.voices = [] }
    // Each pass changes something that can be heard: the first note goes up a fifth and back.
    if var voice = recipe.voices.first, !voice.notes.isEmpty {
      voice.notes[0].pitch = voice.notes[0].pitch == "B5" ? "E5" : "B5"
      recipe.voices[0] = voice
    }
    return recipe.encoded()
  }
}

extension ClaudeCodeAgentProvider: AlertSoundGeneratingProviding {
  public func alertSoundGenerator() -> any AlertSoundGenerating {
    CommandLineAlertSoundGenerator(provider: self, command: ClaudeCodeAlertSoundCommand())
  }
}

extension CodexAgentProvider: AlertSoundGeneratingProviding {
  public func alertSoundGenerator() -> any AlertSoundGenerating {
    CommandLineAlertSoundGenerator(provider: self, command: CodexAlertSoundCommand())
  }
}

extension MockAgentProvider: AlertSoundGeneratingProviding {
  public func alertSoundGenerator() -> any AlertSoundGenerating {
    MockAlertSoundGenerator(environment: environment)
  }
}
