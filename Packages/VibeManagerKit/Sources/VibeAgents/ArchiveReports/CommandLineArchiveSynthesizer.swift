import Foundation
import VibeApplication
import VibeProcess

/// What a paragraph over archived sessions asks of a CLI, and how its answer is read (#408): the
/// archive rules' commands, with the synthesis's instructions and schema.
public protocol ArchiveSynthesisCommand: Sendable {
  func arguments(for request: ArchiveSynthesisRequest, in workspace: URL) throws -> [String]
  var additionalEnvironment: [String: String] { get }
  func input(for request: ArchiveSynthesisRequest) -> Data
  /// The answer, as the agent wrote it: checked by `ArchiveSynthesisAnswer`, not here.
  func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data
}

/// One paragraph: the agent's CLI with its own account, in a process without a terminal, run from
/// an empty temporary folder, without tools, MCP servers, hooks, web search nor memory.
public struct CommandLineArchiveSynthesizer: ArchiveSynthesizing {
  /// A paragraph over a few kilobytes: well under a minute, with room for a slow account.
  public static let timeout: Duration = .seconds(120)

  private let provider: any AgentProvider
  private let command: any ArchiveSynthesisCommand
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, command: any ArchiveSynthesisCommand,
    runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.command = command
    self.runner = runner
  }

  public func synthesize(_ request: ArchiveSynthesisRequest) async throws -> Data {
    let run = OneShotAgentRun(
      provider: provider, runner: runner, folderPrefix: "VibeManager-report-",
      timeout: Self.timeout)
    do {
      return try await run.run { workspace, _ in
        OneShotAgentRun.Invocation(
          arguments: try command.arguments(for: request, in: workspace),
          environment: command.additionalEnvironment,
          input: command.input(for: request))
      } read: { result, workspace in
        guard !result.didTimeOut else { throw ArchiveSynthesisError.timedOut }
        return try command.answer(from: result, in: workspace)
      }
    } catch let failure as OneShotAgentRun.Failure {
      switch failure {
      case .unavailable: throw ArchiveSynthesisError.noAgent
      case .noWorkspace: throw ArchiveSynthesisError.failed("no temporary folder")
      case .noLaunchPlan: throw ArchiveSynthesisError.failed("no launch plan")
      case .couldNotStart: throw ArchiveSynthesisError.failed("could not start")
      }
    }
  }
}

/// `claude -p` without tools, held to the schema. Haiku, as the journal's summary: a paragraph
/// over sentences already written.
public struct ClaudeCodeArchiveSynthesisCommand: ArchiveSynthesisCommand {
  public static let model = "haiku"

  public init() {
    // Nothing to set: the command is the same for every report.
  }

  public func arguments(for request: ArchiveSynthesisRequest, in _: URL) throws -> [String] {
    StructuredAnswerCommand.claude(
      model: Self.model,
      systemPrompt: ArchiveSynthesisInstructions.systemPrompt(language: request.language),
      schema: ArchiveSynthesisSchema.forAgent())
  }

  public var additionalEnvironment: [String: String] { StructuredAnswerCommand.claudeEnvironment }

  public func input(for request: ArchiveSynthesisRequest) -> Data {
    Data(ArchiveSynthesisInstructions.input(for: request).utf8)
  }

  public func answer(from result: BoundedProcessResult, in _: URL) throws -> Data {
    switch StructuredAnswerCommand.claudeAnswer(from: result) {
    case .failed: throw ArchiveSynthesisError.failed("exit \(result.exitCode)")
    case .unstructured: throw ArchiveSynthesisError.unreadable
    case .structured(let data): return data
    }
  }
}

/// `codex exec`, ephemeral, read-only, without network nor the user's configuration, its last
/// message written to a file and held to the schema. The instructions lead the input.
public struct CodexArchiveSynthesisCommand: ArchiveSynthesisCommand {
  static let schemaFile = "schema.json"
  static let answerFile = "answer.json"

  public init() {
    // Nothing to set: the command is the same for every report.
  }

  public func arguments(for _: ArchiveSynthesisRequest, in workspace: URL) throws -> [String] {
    let schema = workspace.appendingPathComponent(Self.schemaFile)
    do {
      try Data(ArchiveSynthesisSchema.forAgent().utf8).write(to: schema)
    } catch {
      throw ArchiveSynthesisError.failed("no schema file")
    }
    return StructuredAnswerCommand.codex(
      schema: schema, answer: workspace.appendingPathComponent(Self.answerFile))
  }

  public var additionalEnvironment: [String: String] { [:] }

  public func input(for request: ArchiveSynthesisRequest) -> Data {
    Data(
      (ArchiveSynthesisInstructions.systemPrompt(language: request.language) + "\n\n"
        + ArchiveSynthesisInstructions.input(for: request)).utf8)
  }

  public func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data {
    guard result.exitCode == 0 else {
      throw ArchiveSynthesisError.failed("exit \(result.exitCode)")
    }
    guard
      let data = StructuredAnswerCommand.codexAnswer(
        in: workspace.appendingPathComponent(Self.answerFile),
        limit: ArchiveSynthesisAnswer.maximumSize)
    else { throw ArchiveSynthesisError.failed("no answer") }
    return data
  }
}

/// A paragraph at once, for the application's scenarios and a copy without any agent. With
/// `VIBE_MOCK_ARCHIVE_SYNTHESIS=fail`, a failure.
public struct MockArchiveSynthesizer: ArchiveSynthesizing {
  private let behaviour: String?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    behaviour = environment["VIBE_MOCK_ARCHIVE_SYNTHESIS"]
  }

  public func synthesize(_ request: ArchiveSynthesisRequest) async throws -> Data {
    if behaviour == "fail" { throw ArchiveSynthesisError.failed("mock") }
    let sessions = request.material.components(separatedBy: "\n").filter {
      $0.hasPrefix("Session: ")
    }.count
    let answer = ["summary": "\(sessions) sessions archived; the work they describe is done."]
    return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
  }
}

extension ClaudeCodeAgentProvider: ArchiveSynthesizingProviding {
  public func archiveSynthesizer() -> any ArchiveSynthesizing {
    CommandLineArchiveSynthesizer(provider: self, command: ClaudeCodeArchiveSynthesisCommand())
  }
}

extension CodexAgentProvider: ArchiveSynthesizingProviding {
  public func archiveSynthesizer() -> any ArchiveSynthesizing {
    CommandLineArchiveSynthesizer(provider: self, command: CodexArchiveSynthesisCommand())
  }
}

extension MockAgentProvider: ArchiveSynthesizingProviding {
  public func archiveSynthesizer() -> any ArchiveSynthesizing {
    MockArchiveSynthesizer(environment: environment)
  }
}
