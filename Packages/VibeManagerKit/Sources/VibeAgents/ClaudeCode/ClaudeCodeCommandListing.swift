import Foundation
import VibeApplication
import VibeProcess

/// Asks Claude Code what a prompt may invoke: the answer to the `initialize` request of its
/// `stream-json` protocol, which lists every skill and command the session would accept (#219).
public protocol ClaudeCodeCommandReading: Sendable {
  /// The `response` of the `initialize` request, as the JSON the CLI wrote.
  func initializeResponse(plan: AgentLaunchPlan) async throws -> Data
}

public enum ClaudeCodeCommandError: Error, Hashable, Sendable {
  case timedOut
  case unreadableAnswer
  case failed(String)
}

/// `claude -p` over its standard input and output, with the plan's executable, environment —
/// `CLAUDE_CONFIG_DIR` above all — and folder, so it lists what the session's agent reads.
///
/// Measured against 2.1.285: the answer comes in 1 s and the model is never called. The user's
/// hooks are turned off — a `SessionStart` hook would believe a session started — nothing is
/// written to the transcripts, and none of the user's MCP servers is started: without
/// `--strict-mcp-config`, each reading started three of them, for the same list.
public struct ClaudeCodeCommandProcess: ClaudeCodeCommandReading {
  static let arguments = [
    "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#,
    "--strict-mcp-config",
  ]
  static let request = Data(
    #"{"type":"control_request","request_id":"vibe-commands","request":{"subtype":"initialize"}}"#
      .utf8 + [0x0A])

  private let timeout: Duration

  public init(timeout: Duration = .seconds(10)) {
    self.timeout = timeout
  }

  public func initializeResponse(plan: AgentLaunchPlan) async throws -> Data {
    // The CLI ends once its input does: the input stays open until the answer has come.
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: plan.executablePath, arguments: Self.arguments,
        environment: plan.environment, workingDirectoryPath: plan.workingDirectoryPath,
        timeout: timeout, outputByteLimit: 4 * 1024 * 1024,
        standardInput: BoundedProcessInput(
          data: Self.request, closeOnceOutputContains: Data(#""control_response""#.utf8))))
    // An answer written counts even if the CLI took long to leave after it.
    if let answer = try? Self.answer(in: result.standardOutput) { return answer }
    if result.didTimeOut { throw ClaudeCodeCommandError.timedOut }
    return try Self.answer(in: result.standardOutput)
  }

  /// The `response` of the answer to the request, out of everything the CLI wrote.
  static func answer(in output: Data) throws -> Data {
    for line in output.split(separator: 0x0A) {
      guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
        message["type"] as? String == "control_response",
        let response = message["response"] as? [String: Any]
      else { continue }
      if let answer = response["response"] as? [String: Any] {
        return try JSONSerialization.data(withJSONObject: answer)
      }
      throw ClaudeCodeCommandError.failed(response["error"] as? String ?? "error")
    }
    throw ClaudeCodeCommandError.unreadableAnswer
  }
}

/// Turns the CLI's list into commands for the composer.
public enum ClaudeCodeCommands {
  /// Left out: plumbing of sessions the server launches, commands the CLI keeps only to say they
  /// are gone, and those whose result is drawn in the terminal alone — the conversation would show
  /// nothing of it.
  static let hiddenNames: Set<String> = ["workflow-launch-exec", "usage", "context"]

  /// - Parameters:
  ///   - response: the `response` of the `initialize` request.
  ///   - configurationDirectory: `CLAUDE_CONFIG_DIR`, where the user's own skills are.
  public static func list(
    from response: Data, workingDirectoryPath: String, configurationDirectory: URL,
    fileManager: FileManager = .default
  ) throws -> AgentCommandList {
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      let entries = object["commands"] as? [[String: Any]]
    else { throw ClaudeCodeCommandError.unreadableAnswer }
    let project = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
      .appendingPathComponent(".claude/skills", isDirectory: true)
    let user = configurationDirectory.appendingPathComponent("skills", isDirectory: true)
    func hasSkill(_ name: String, in directory: URL) -> Bool {
      fileManager.fileExists(
        atPath: directory.appendingPathComponent(name).appendingPathComponent("SKILL.md").path)
    }

    var seen: Set<String> = []
    var commands: [AgentCommand] = []
    for entry in entries {
      guard let name = entry["name"] as? String, !name.isEmpty, !name.hasPrefix("__"),
        !name.contains(where: \.isWhitespace), !hiddenNames.contains(name),
        seen.insert(name).inserted
      else { continue }
      var description = (entry["description"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if description.hasPrefix("(removed)") || description.hasPrefix("Renamed to") { continue }
      let aliases = (entry["aliases"] as? [String] ?? []).filter { !$0.isEmpty }
      let kind: AgentCommand.Kind
      let origin: AgentCommand.Origin?
      if entry["builtin"] as? Bool == true {
        kind = .command
        origin = .builtin
      } else if let stripped = strippingSuffix("(user)", of: description) {
        // A command of `commands/`: the CLI says whose.
        description = stripped
        kind = .command
        origin = .user
      } else if let stripped = strippingSuffix("(project)", of: description) {
        description = stripped
        kind = .command
        origin = .project
      } else if let colon = name.firstIndex(of: ":") {
        // A plugin's: its name comes first, and the CLI repeats it — as the plugin calls itself —
        // at the head of the description.
        description = strippingParenthesizedPrefix(of: description)
        kind = .skill
        origin = .plugin(String(name[..<colon]))
      } else if hasSkill(name, in: project) {
        kind = .skill
        origin = .project
      } else if hasSkill(name, in: user) {
        kind = .skill
        origin = .user
      } else if let alias = aliases.first(where: { $0.contains(":") }) {
        // A skill brought from claude.ai answers to its namespaced name too.
        kind = .skill
        origin = .plugin(String(alias.prefix { $0 != ":" }))
      } else {
        kind = .skill
        origin = nil
      }
      commands.append(
        AgentCommand(
          name: name, invocation: "/" + name, description: description,
          argumentHint: entry["argumentHint"] as? String, kind: kind, origin: origin,
          aliases: aliases.filter { !$0.contains(":") }))
    }
    return AgentCommandList(commands: commands)
  }

  private static func strippingSuffix(_ suffix: String, of text: String) -> String? {
    guard text.hasSuffix(suffix) else { return nil }
    return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
  }

  private static func strippingParenthesizedPrefix(of text: String) -> String {
    guard text.hasPrefix("("), let close = text.firstIndex(of: ")") else { return text }
    return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
  }
}

extension ClaudeCodeAgentProvider: AgentCommandListing {
  public func commands(inWorkingDirectory workingDirectoryPath: String, refresh: Bool)
    async throws -> AgentCommandList
  {
    let plan = try await launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: workingDirectoryPath))
    let response = try await commandReader.initializeResponse(plan: plan)
    return try ClaudeCodeCommands.list(
      from: response, workingDirectoryPath: workingDirectoryPath,
      configurationDirectory: ClaudeCodeHome.directory(environment: plan.environment))
  }
}
