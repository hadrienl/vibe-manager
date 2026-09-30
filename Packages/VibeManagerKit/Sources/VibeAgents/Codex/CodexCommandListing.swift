import Foundation
import VibeApplication

/// Turns what Codex says of its skills into commands for the composer (#219).
///
/// Measured against 0.159.2: `skills/list` of its app-server answers in 0.3 s with every skill the
/// session would load — the user's, the folder's, the plugins', its own — and the skills it could
/// not read. Codex invokes a skill with `$`, and its commands with `/`; it lists no command, so its
/// own are named here.
public enum CodexCommands {
  public enum Error: Swift.Error, Hashable, Sendable {
    case unreadableAnswer
  }

  /// Codex's own commands whose effect shows in the conversation. Those that open a panel of the
  /// terminal — `/model`, `/status`, `/diff`, `/review`'s picker — or start another conversation
  /// — `/new` — are left to the terminal.
  static var builtins: [AgentCommand] {
    [
      AgentCommand(
        name: "compact", invocation: "/compact",
        description: String(
          localized: "Summarize the conversation to free up context.", bundle: .module,
          comment: "Codex's /compact command, in the composer's list."),
        kind: .command, origin: .builtin),
      AgentCommand(
        name: "init", invocation: "/init",
        description: String(
          localized: "Create an AGENTS.md file with instructions for Codex.", bundle: .module,
          comment: "Codex's /init command, in the composer's list."),
        kind: .command, origin: .builtin),
    ]
  }

  /// - Parameter result: the `result` of `skills/list`.
  public static func skills(from result: Data) throws -> AgentCommandList {
    guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
      let folders = object["data"] as? [[String: Any]]
    else { throw Error.unreadableAnswer }
    var seen: Set<String> = []
    var commands: [AgentCommand] = []
    var problems: [AgentCommandProblem] = []
    for folder in folders {
      for error in folder["errors"] as? [[String: Any]] ?? [] {
        problems.append(
          AgentCommandProblem(
            path: error["path"] as? String ?? "", message: error["message"] as? String ?? ""))
      }
      for skill in folder["skills"] as? [[String: Any]] ?? [] {
        guard skill["enabled"] as? Bool != false, let name = skill["name"] as? String,
          !name.isEmpty, !name.contains(where: \.isWhitespace), seen.insert(name).inserted
        else { continue }
        let interface = skill["interface"] as? [String: Any]
        let description =
          [interface?["shortDescription"], skill["shortDescription"], skill["description"]]
          .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first { !$0.isEmpty } ?? ""
        commands.append(
          AgentCommand(
            name: name, invocation: "$" + name, description: description, kind: .skill,
            origin: origin(scope: skill["scope"] as? String, plugin: skill["pluginId"] as? String)
          ))
      }
    }
    return AgentCommandList(commands: commands, problems: problems)
  }

  /// `prisme-ai@prismeai-mcp` is the plugin `prisme-ai`, from its marketplace.
  static func origin(scope: String?, plugin: String?) -> AgentCommand.Origin? {
    if let plugin, !plugin.isEmpty {
      return .plugin(String(plugin.prefix { $0 != "@" }))
    }
    switch scope {
    case "repo": return .project
    case "user": return .user
    case "system", "admin": return .system
    default: return nil
    }
  }

  /// The prompts of `$CODEX_HOME/prompts`, invoked as `/prompts:<name>`: Codex's app-server does
  /// not list them. Read only when the folder exists; a file that cannot be read is left out.
  public static func prompts(in codexHome: URL, fileManager: FileManager = .default)
    -> AgentCommandList
  {
    let folder = codexHome.appendingPathComponent("prompts", isDirectory: true)
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return AgentCommandList(commands: []) }
    var commands: [AgentCommand] = []
    var problems: [AgentCommandProblem] = []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where file.pathExtension == "md" {
      let name = file.deletingPathExtension().lastPathComponent
      guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { continue }
      guard let data = try? Data(contentsOf: file), data.count <= 256 * 1024,
        let text = String(data: data, encoding: .utf8),
        let document = MarkdownFrontMatter(text)
      else {
        problems.append(AgentCommandProblem(path: file.path, message: "unreadable"))
        continue
      }
      commands.append(
        AgentCommand(
          name: "prompts:" + name, invocation: "/prompts:" + name,
          description: document.fields["description"] ?? document.firstLine ?? "",
          argumentHint: document.fields["argument-hint"], kind: .command, origin: .user))
    }
    return AgentCommandList(commands: commands, problems: problems)
  }
}

/// The `key: value` lines between two `---` opening a Markdown file, and the first line of text
/// after them: what a prompt or a command says of itself.
struct MarkdownFrontMatter {
  let fields: [String: String]
  let firstLine: String?

  /// `nil` for a front matter opened and never closed.
  init?(_ text: String) {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }[...]
    var fields: [String: String] = [:]
    if lines.first == "---" {
      lines = lines.dropFirst()
      guard let end = lines.firstIndex(of: "---") else { return nil }
      for line in lines[..<end] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
          value.last == quote
        {
          value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty, !value.isEmpty { fields[key] = value }
      }
      lines = lines[(end + 1)...]
    }
    self.fields = fields
    firstLine = lines.first { !$0.isEmpty }.map {
      $0.hasPrefix("#") ? $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) : $0
    }
  }
}

extension CodexAgentProvider: AgentCommandListing {
  public func commands(inWorkingDirectory workingDirectoryPath: String, refresh: Bool)
    async throws -> AgentCommandList
  {
    let plan = try await launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: workingDirectoryPath))
    let params = try JSONSerialization.data(withJSONObject: [
      "cwds": [workingDirectoryPath], "forceReload": refresh,
    ])
    let skills = try CodexCommands.skills(
      from: await appServer.call(plan: plan, options: [], method: "skills/list", params: params))
    let prompts = CodexCommands.prompts(in: CodexHome.directory(environment: plan.environment))
    return AgentCommandList(
      commands: skills.commands + prompts.commands + CodexCommands.builtins,
      problems: skills.problems + prompts.problems)
  }
}
