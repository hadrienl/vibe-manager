import Foundation
import VibeApplication

/// Claude Code loads tool servers from `--mcp-config`, which adds to the user's own servers rather
/// than replacing them (no `--strict-mcp-config`). Each server's tools are allowed with
/// `--allowedTools mcp__<name>`: Vibe Manager asks for itself before anything is done as the user
/// (ADR 0023), and Claude asking again for the same call would be a second question with no new
/// answer.
extension ClaudeCodeAgentProvider: AgentToolServing {
  public func providingTools(_ servers: [AgentToolServer], to plan: AgentLaunchPlan)
    -> AgentLaunchPlan
  {
    guard !servers.isEmpty else { return plan }
    return plan.adding(options: ClaudeCodeToolOptions.options(for: servers))
  }
}

public enum ClaudeCodeToolOptions {
  public static func options(for servers: [AgentToolServer]) -> [String] {
    var entries: [String: Any] = [:]
    for server in servers {
      entries[server.name] = [
        "type": "stdio", "command": server.executablePath, "args": server.arguments,
      ]
    }
    let data = try? JSONSerialization.data(
      withJSONObject: ["mcpServers": entries], options: [.sortedKeys, .withoutEscapingSlashes])
    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return ["--mcp-config", json]
      + servers.flatMap { ["--allowedTools", "mcp__\($0.name)"] }
  }
}

/// Codex reads tool servers from its configuration, overridden for this launch with `-c`. The
/// values are TOML, written here rather than by a shell: every argument reaches the CLI as it is.
extension CodexAgentProvider: AgentToolServing {
  public func providingTools(_ servers: [AgentToolServer], to plan: AgentLaunchPlan)
    -> AgentLaunchPlan
  {
    guard !servers.isEmpty else { return plan }
    return plan.adding(options: CodexToolOptions.options(for: servers))
  }
}

public enum CodexToolOptions {
  public static func options(for servers: [AgentToolServer]) -> [String] {
    servers.flatMap { server in
      [
        "-c", "mcp_servers.\(server.name).command=\(tomlString(server.executablePath))",
        "-c",
        "mcp_servers.\(server.name).args=["
          + server.arguments.map(tomlString).joined(separator: ",") + "]",
      ]
    }
  }

  /// A TOML basic string: quotes and backslashes escaped, control characters as `\uXXXX`.
  static func tomlString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\t": result += "\\t"
      case "\r": result += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          result += String(format: "\\u%04X", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result + "\""
  }
}

/// Claude Code adds `--append-system-prompt` to its own system prompt, which it keeps (#352).
extension ClaudeCodeAgentProvider: AgentInstructing {
  public func instructing(_ instructions: String, to plan: AgentLaunchPlan) -> AgentLaunchPlan {
    plan.adding(options: ["--append-system-prompt", instructions])
  }
}

/// Codex reads `developer_instructions` from its configuration, given for this launch with `-c`
/// (#352). The option replaces those of the user's configuration for this launch: they are read
/// and kept in front (#432), since every session is now given instructions.
extension CodexAgentProvider: AgentInstructing {
  public func instructing(_ instructions: String, to plan: AgentLaunchPlan) -> AgentLaunchPlan {
    let home =
      plan.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    let configuration = try? String(
      contentsOfFile: (home as NSString).appendingPathComponent("config.toml"), encoding: .utf8)
    let own = configuration.flatMap(CodexToolOptions.developerInstructions(in:))
    let merged = own.map { $0 + "\n\n" + instructions } ?? instructions
    return plan.adding(options: [
      "-c", "developer_instructions=\(CodexToolOptions.tomlString(merged))",
    ])
  }
}

extension CodexToolOptions {
  /// The top-level `developer_instructions` of a Codex configuration: a basic, literal or
  /// multi-line string, before any table. `nil` when there is none, or it is not read.
  static func developerInstructions(in configuration: String) -> String? {
    var rest = Substring(configuration)
    while !rest.isEmpty {
      let line = rest.prefix { $0 != "\n" }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { return nil }
      if trimmed.hasPrefix("developer_instructions"), let equal = line.firstIndex(of: "="),
        trimmed.dropFirst("developer_instructions".count).drop(while: \.isWhitespace).first == "="
      {
        let start = rest.index(after: equal)
        let value = rest[start...].drop { $0 == " " || $0 == "\t" }
        for (open, close, escapes) in [
          ("\"\"\"", "\"\"\"", true), ("'''", "'''", false), ("\"", "\"", true),
          ("'", "'", false),
        ] where value.hasPrefix(open) {
          let body = value.dropFirst(open.count).drop { open.count == 3 && $0 == "\n" }
          var text = ""
          var index = body.startIndex
          while index < body.endIndex {
            if body[index...].hasPrefix(close) { return text }
            let character = body[index]
            if escapes, character == "\\", body.index(after: index) < body.endIndex {
              index = body.index(after: index)
              switch body[index] {
              case "n": text.append("\n")
              case "t": text.append("\t")
              case "\n":
                index = body[index...].firstIndex { !$0.isWhitespace } ?? body.endIndex
                continue
              default: text.append(body[index])
              }
            } else {
              text.append(character)
            }
            index = body.index(after: index)
          }
          return nil
        }
        return nil
      }
      rest = rest.dropFirst(line.count).dropFirst()
    }
    return nil
  }
}
