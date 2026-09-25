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
