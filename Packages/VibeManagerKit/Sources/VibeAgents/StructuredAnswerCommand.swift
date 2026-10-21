import Foundation
import VibeProcess

/// A CLI asked to answer with data alone (#118, #393): no tools, no MCP servers, no hooks, no
/// settings, no memory and nothing left behind, its answer held to a JSON schema. A theme and a
/// sound share these words, so that a guard added for one is added for both.
enum StructuredAnswerCommand {
  /// What `claude -p` answered.
  enum ClaudeAnswer {
    /// It did not answer: its exit, or an error it reported.
    case failed
    /// It answered without the structured output the schema asks for.
    case unstructured
    case structured(Data)
  }

  /// `claude -p`, `systemPrompt` as its only instructions, the answer on its standard output.
  static func claude(model: String, systemPrompt: String, schema: String) -> [String] {
    [
      "-p", "--model", model, "--tools", "", "--strict-mcp-config",
      "--no-session-persistence", "--setting-sources", "",
      "--settings", #"{"disableAllHooks":true}"#,
      "--system-prompt", systemPrompt,
      "--output-format", "json",
      "--json-schema", schema,
    ]
  }

  /// Claude Code's own memory stays out of the answer.
  static let claudeEnvironment = ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]

  /// The `structured_output` of `claude -p --output-format json`.
  static func claudeAnswer(from result: BoundedProcessResult) -> ClaudeAnswer {
    let answer = (try? JSONSerialization.jsonObject(with: result.standardOutput)) as? [String: Any]
    guard result.exitCode == 0, let answer, answer["is_error"] as? Bool != true else {
      return .failed
    }
    guard let structured = answer["structured_output"],
      JSONSerialization.isValidJSONObject(structured),
      let data = try? JSONSerialization.data(withJSONObject: structured)
    else { return .unstructured }
    return .structured(data)
  }

  /// `codex exec`: ephemeral, read only, outside any repository and without the user's
  /// configuration, its instructions on the standard input and its last message written to
  /// `answer`.
  static func codex(schema: URL, answer: URL) -> [String] {
    [
      "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
      "-s", "read-only",
      "--disable", "hooks", "--disable", "apps", "--disable", "plugins",
      "-c", "mcp_servers={}", "-c", "tools.web_search=false",
      "--output-schema", schema.path, "-o", answer.path,
      "-",
    ]
  }

  /// The last message Codex wrote: never more than `limit` bytes, and one more to tell. `nil`
  /// when it wrote none.
  static func codexAnswer(in file: URL, limit: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
    return data.isEmpty ? nil : data
  }
}
