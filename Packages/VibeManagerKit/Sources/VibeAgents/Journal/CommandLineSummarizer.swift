import Foundation
import VibeApplication
import VibeDomain
import VibeProcess

/// Runs a summary command. `BoundedProcess` in the application, a double in the tests.
public protocol SummaryProcessRunning: Sendable {
  func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult
}

public struct BoundedSummaryProcessRunner: SummaryProcessRunning {
  public init() {}

  public func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    try await BoundedProcess.run(request)
  }
}

/// What a summary asks of a CLI, and how its answer is read (#36).
public protocol SummaryCommand: Sendable {
  /// The arguments, given the folder the command runs in: files it needs are written there.
  func arguments(for request: SummaryRequest, in workspace: URL, models: [AgentModel]) throws
    -> [String]
  /// Variables added to the plan's own.
  var additionalEnvironment: [String: String] { get }
  /// What goes on the standard input.
  func input(for request: SummaryRequest) -> Data
  /// The entries of the answer.
  func entries(from result: BoundedProcessResult, in workspace: URL, request: SummaryRequest)
    throws -> [SummaryEntry]
}

/// One summary: the session's CLI, with its own executable and environment — the same account —
/// in a process without a terminal, run from an empty temporary folder so that no `CLAUDE.md` or
/// `AGENTS.md` is found, and never in the session's conversation.
public struct CommandLineSummarizer: SessionSummarizing {
  public static let timeout: Duration = .seconds(90)

  private let provider: any AgentProvider
  private let command: any SummaryCommand
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, command: any SummaryCommand,
    runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.command = command
    self.runner = runner
  }

  public func summarize(_ request: SummaryRequest) async throws -> [SummaryEntry] {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VibeManager-summary-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw SummaryError.failed("no temporary folder")
    }
    defer { try? FileManager.default.removeItem(at: workspace) }

    let plan: AgentLaunchPlan
    do {
      plan = try await provider.launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: workspace.path))
    } catch AgentLaunchError.unavailable(let state) {
      throw SummaryError.unavailable(Self.unavailability(state))
    } catch {
      throw SummaryError.failed("no launch plan")
    }
    let arguments = try command.arguments(
      for: request, in: workspace, models: await provider.models())
    var environment = plan.environment
    environment.merge(command.additionalEnvironment) { _, added in added }
    let result: BoundedProcessResult
    do {
      result = try await runner.run(
        BoundedProcessRequest(
          executablePath: plan.executablePath, arguments: arguments, environment: environment,
          workingDirectoryPath: workspace.path, timeout: Self.timeout,
          standardInput: BoundedProcessInput(data: command.input(for: request))))
    } catch BoundedProcessError.cancelled {
      throw CancellationError()
    } catch {
      throw SummaryError.failed("could not start")
    }
    guard !result.didTimeOut else { throw SummaryError.failed("timed out") }
    return try command.entries(from: result, in: workspace, request: request)
  }

  static func unavailability(_ state: AgentAvailabilityState) -> JournalSummaryUnavailability {
    switch state {
    case .unauthenticated: return .signedOut
    case .outdated: return .outdated
    default: return .missing
    }
  }

  /// Why a CLI that exited in error did, as far as its error output tells: an option it does not
  /// know means it is too old, a word about logging in means it is signed out.
  static func failure(of result: BoundedProcessResult) -> SummaryError {
    let error = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
      .lowercased()
    if error.contains("unknown option") || error.contains("unexpected argument")
      || error.contains("unrecognized") || error.contains("unknown feature flag")
    {
      return .unavailable(.outdated)
    }
    if error.contains("/login") || error.contains("not logged in") || error.contains("log in")
      || error.contains("invalid api key")
    {
      return .unavailable(.signedOut)
    }
    return .failed("exit \(result.exitCode)")
  }
}

/// `claude -p`: no tools, no MCP, no hooks, no settings, no memory and no transcript left behind,
/// its own system prompt in place of the agent's, and an answer held to a JSON schema.
public struct ClaudeCodeSummaryCommand: SummaryCommand {
  public static let model = "haiku"

  public init() {}

  public func arguments(
    for request: SummaryRequest, in workspace: URL, models: [AgentModel]
  ) throws -> [String] {
    [
      "-p", "--model", Self.model, "--tools", "", "--strict-mcp-config",
      "--no-session-persistence", "--setting-sources", "",
      "--settings", #"{"disableAllHooks":true}"#,
      "--system-prompt", SummaryInstructions.systemPrompt(language: request.language),
      "--output-format", "json", "--json-schema", SummaryInstructions.schema,
    ]
  }

  /// Without it, every call would leave a `memory` folder under a project named after the
  /// temporary folder.
  public var additionalEnvironment: [String: String] { ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"] }

  public func input(for request: SummaryRequest) -> Data { Data(request.digest.utf8) }

  public func entries(
    from result: BoundedProcessResult, in workspace: URL, request: SummaryRequest
  ) throws -> [SummaryEntry] {
    let answer = (try? JSONSerialization.jsonObject(with: result.standardOutput)) as? [String: Any]
    guard result.exitCode == 0, let answer, answer["is_error"] as? Bool != true else {
      throw CommandLineSummarizer.failure(of: result)
    }
    guard let structured = answer["structured_output"] else {
      throw SummaryError.failed("no structured output")
    }
    return try SummaryInstructions.entries(from: structured, turnCount: request.turnCount)
  }
}

/// `codex exec`: ephemeral, read only, outside any repository, its last message written to a file
/// and held to a JSON schema. Codex takes no system prompt: the instructions lead the input.
public struct CodexSummaryCommand: SummaryCommand {
  static let schemaFile = "schema.json"
  static let answerFile = "answer.json"

  public init() {}

  public func arguments(
    for request: SummaryRequest, in workspace: URL, models: [AgentModel]
  ) throws -> [String] {
    let schema = workspace.appendingPathComponent(Self.schemaFile)
    do {
      try Data(SummaryInstructions.schema.utf8).write(to: schema)
    } catch {
      throw SummaryError.failed("no schema file")
    }
    // Without the user's hooks, MCP servers, apps, plugins or web search: the digest carries text
    // from the web and from tickets, and nothing it says must reach a tool that can act. What is
    // left — a shell — runs in the read-only sandbox, without the network.
    var arguments = [
      "exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
      "--disable", "hooks", "--disable", "apps", "--disable", "plugins",
      "-c", "mcp_servers={}", "-c", "tools.web_search=false",
    ]
    // The lightest model the catalog offers, or the configured one.
    if let light = models.first(where: { $0.id.lowercased().contains("mini") }) {
      arguments += ["-m", light.id]
    }
    arguments += [
      "--output-schema", schema.path, "-o", workspace.appendingPathComponent(Self.answerFile).path,
      "-",
    ]
    return arguments
  }

  public var additionalEnvironment: [String: String] { [:] }

  public func input(for request: SummaryRequest) -> Data {
    Data(
      (SummaryInstructions.systemPrompt(language: request.language) + "\n\n" + request.digest)
        .utf8)
  }

  public func entries(
    from result: BoundedProcessResult, in workspace: URL, request: SummaryRequest
  ) throws -> [SummaryEntry] {
    guard result.exitCode == 0 else { throw CommandLineSummarizer.failure(of: result) }
    guard let data = try? Data(contentsOf: workspace.appendingPathComponent(Self.answerFile)),
      let answer = try? JSONSerialization.jsonObject(with: data)
    else { throw SummaryError.failed("no answer") }
    return try SummaryInstructions.entries(from: answer, turnCount: request.turnCount)
  }
}

extension ClaudeCodeAgentProvider: SessionSummarizingProviding {
  public func sessionSummarizer() -> any SessionSummarizing {
    CommandLineSummarizer(provider: self, command: ClaudeCodeSummaryCommand())
  }
}

extension CodexAgentProvider: SessionSummarizingProviding {
  public func sessionSummarizer() -> any SessionSummarizing {
    CommandLineSummarizer(provider: self, command: CodexSummaryCommand())
  }
}
