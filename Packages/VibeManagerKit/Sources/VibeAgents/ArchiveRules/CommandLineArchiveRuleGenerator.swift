import Foundation
import VibeApplication
import VibeProcess

/// What a translation into archive rules asks of a CLI, and how its answer is read (#405): the
/// themes' commands (#118), with the rules' instructions and schema.
public protocol ArchiveRuleCommand: Sendable {
  func arguments(for request: ArchiveRuleGenerationRequest, in workspace: URL) throws -> [String]
  var additionalEnvironment: [String: String] { get }
  func input(for request: ArchiveRuleGenerationRequest) -> Data
  /// The answer, as the agent wrote it: checked by `GenerateArchiveRules`, not here.
  func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data
}

/// One translation: the agent's CLI with its own account, in a process without a terminal, run
/// from an empty temporary folder, without tools, MCP servers, hooks, web search nor memory —
/// what it answers is data, held to the schema, read by the application's parser.
public struct CommandLineArchiveRuleGenerator: ArchiveRuleGenerating {
  /// A few lines of rules: well under a minute, with room for a slow account.
  public static let timeout: Duration = .seconds(120)

  private let provider: any AgentProvider
  private let command: any ArchiveRuleCommand
  private let runner: any SummaryProcessRunning

  public init(
    provider: any AgentProvider, command: any ArchiveRuleCommand,
    runner: any SummaryProcessRunning = BoundedSummaryProcessRunner()
  ) {
    self.provider = provider
    self.command = command
    self.runner = runner
  }

  public func generate(_ request: ArchiveRuleGenerationRequest) async throws -> Data {
    let run = OneShotAgentRun(
      provider: provider, runner: runner, folderPrefix: "VibeManager-rules-",
      timeout: Self.timeout)
    do {
      return try await run.run { workspace, _ in
        OneShotAgentRun.Invocation(
          arguments: try command.arguments(for: request, in: workspace),
          environment: command.additionalEnvironment,
          input: command.input(for: request))
      } read: { result, workspace in
        guard !result.didTimeOut else { throw ArchiveRuleGenerationError.timedOut }
        return try command.answer(from: result, in: workspace)
      }
    } catch let failure as OneShotAgentRun.Failure {
      switch failure {
      case .unavailable(let state):
        throw ArchiveRuleGenerationError.unavailable(Self.unavailability(state))
      case .noWorkspace: throw ArchiveRuleGenerationError.failed("no temporary folder")
      case .noLaunchPlan: throw ArchiveRuleGenerationError.failed("no launch plan")
      case .couldNotStart: throw ArchiveRuleGenerationError.failed("could not start")
      }
    }
  }

  static func unavailability(_ state: AgentAvailabilityState)
    -> ArchiveRuleGenerationError.Unavailability
  {
    switch state {
    case .unauthenticated: .signedOut
    case .outdated: .outdated
    default: .missing
    }
  }

  static func failure(of result: BoundedProcessResult) -> ArchiveRuleGenerationError {
    switch CommandLineSummarizer.failure(of: result) {
    case .unavailable(.outdated): .unavailable(.outdated)
    case .unavailable(.signedOut): .unavailable(.signedOut)
    case .unavailable: .unavailable(.missing)
    case .failed(let reason): .failed(reason)
    }
  }
}

/// `claude -p` without tools, MCP, hooks, settings nor memory, the rules' instructions as its
/// system prompt, the answer held to the schema. Sonnet: a translation that must be exact.
public struct ClaudeCodeArchiveRuleCommand: ArchiveRuleCommand {
  public static let model = "sonnet"

  public init() {
    // Nothing to set: the command is the same for every sentence.
  }

  public func arguments(for request: ArchiveRuleGenerationRequest, in _: URL) throws -> [String] {
    StructuredAnswerCommand.claude(
      model: Self.model,
      systemPrompt: ArchiveRuleInstructions.systemPrompt(context: request.context),
      schema: ArchiveRuleSchema.forAgent())
  }

  public var additionalEnvironment: [String: String] { StructuredAnswerCommand.claudeEnvironment }

  public func input(for request: ArchiveRuleGenerationRequest) -> Data {
    Data(ArchiveRuleInstructions.input(for: request).utf8)
  }

  public func answer(from result: BoundedProcessResult, in _: URL) throws -> Data {
    switch StructuredAnswerCommand.claudeAnswer(from: result) {
    case .failed: throw CommandLineArchiveRuleGenerator.failure(of: result)
    case .unstructured: throw ArchiveRuleGenerationError.failed("no structured output")
    case .structured(let data): return data
    }
  }
}

/// `codex exec`, ephemeral, in its read-only sandbox without network, outside any repository and
/// without the user's configuration, its last message written to a file and held to the schema.
/// The instructions lead the input.
public struct CodexArchiveRuleCommand: ArchiveRuleCommand {
  static let schemaFile = "schema.json"
  static let answerFile = "answer.json"

  public init() {
    // Nothing to set: the command is the same for every sentence.
  }

  public func arguments(for _: ArchiveRuleGenerationRequest, in workspace: URL) throws -> [String] {
    let schema = workspace.appendingPathComponent(Self.schemaFile)
    do {
      try Data(ArchiveRuleSchema.forAgent().utf8).write(to: schema)
    } catch {
      throw ArchiveRuleGenerationError.failed("no schema file")
    }
    return StructuredAnswerCommand.codex(
      schema: schema, answer: workspace.appendingPathComponent(Self.answerFile))
  }

  public var additionalEnvironment: [String: String] { [:] }

  public func input(for request: ArchiveRuleGenerationRequest) -> Data {
    Data(
      (ArchiveRuleInstructions.systemPrompt(context: request.context) + "\n\n"
        + ArchiveRuleInstructions.input(for: request)).utf8)
  }

  public func answer(from result: BoundedProcessResult, in workspace: URL) throws -> Data {
    guard result.exitCode == 0 else { throw CommandLineArchiveRuleGenerator.failure(of: result) }
    guard
      let data = StructuredAnswerCommand.codexAnswer(
        in: workspace.appendingPathComponent(Self.answerFile), limit: ArchiveRuleAnswer.maximumSize)
    else { throw ArchiveRuleGenerationError.failed("no answer") }
    return data
  }
}

/// Rules at once, for the application's scenarios and a copy without any agent: the objective's
/// two rules, or a question when the sentence says “?”. With `VIBE_MOCK_ARCHIVE_RULES=fail`, a
/// failure; `invalid`, an answer that is always refused.
public struct MockArchiveRuleGenerator: ArchiveRuleGenerating {
  private let behaviour: String?

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    behaviour = environment["VIBE_MOCK_ARCHIVE_RULES"]
  }

  public func generate(_ request: ArchiveRuleGenerationRequest) async throws -> Data {
    if behaviour == "fail" { throw ArchiveRuleGenerationError.failed("mock") }
    var answer: [String: Any] = ["rules": NSNull(), "question": NSNull(), "assumptions": []]
    if behaviour == "invalid" {
      answer["rules"] = "rule"
    } else if request.sentence.contains("?"), request.answers.isEmpty {
      answer["question"] = [
        "text": "« Rouge » : Rouge ou Rouge brique ?",
        "choices": ["Rouge", "Rouge brique", "Les deux"],
      ]
    } else {
      answer["rules"] = ArchiveRuleGrammar.examples.components(separatedBy: "\n\nprotect")[0]
      answer["assumptions"] = [
        ["said": "fin de semaine", "chosen": "vendredi"],
        ["said": "sans heure", "chosen": "18:00"],
      ]
    }
    return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
  }
}

extension ClaudeCodeAgentProvider: ArchiveRuleGeneratingProviding {
  public func archiveRuleGenerator() -> any ArchiveRuleGenerating {
    CommandLineArchiveRuleGenerator(provider: self, command: ClaudeCodeArchiveRuleCommand())
  }
}

extension CodexAgentProvider: ArchiveRuleGeneratingProviding {
  public func archiveRuleGenerator() -> any ArchiveRuleGenerating {
    CommandLineArchiveRuleGenerator(provider: self, command: CodexArchiveRuleCommand())
  }
}

extension MockAgentProvider: ArchiveRuleGeneratingProviding {
  public func archiveRuleGenerator() -> any ArchiveRuleGenerating {
    MockArchiveRuleGenerator(environment: environment)
  }
}
