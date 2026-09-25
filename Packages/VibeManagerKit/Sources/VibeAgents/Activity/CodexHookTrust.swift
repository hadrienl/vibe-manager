import Foundation
import VibeApplication
import VibeProcess

/// Asks Codex whether the activity hooks will run, and approves them — only them — when the user
/// agreed to it in Vibe Manager (#45).
///
/// Codex keeps its approvals in `config.toml` (`hooks.state."<key>".trusted_hash`), keyed by the
/// hook's place and fingerprint. They are written through Codex's own local server, with the
/// method its interface uses: the rest of the file — comments included — is left as it was, and
/// Codex itself says afterwards whether the approval took.
public struct CodexHookTrust: Sendable {
  private let connection: any CodexAppServerConnecting

  public init(connection: any CodexAppServerConnecting = CodexAppServerProcess()) {
    self.connection = connection
  }

  public func hookTrust(for plan: AgentLaunchPlan) async -> AgentHookTrust {
    guard let hooks = try? await ourHooks(for: plan) else { return .unknown }
    let pending = hooks.filter { $0.trustStatus != "trusted" }
    guard !pending.isEmpty else { return .trusted }
    return .needsApproval(commands: pending.map(\.command))
  }

  public func trustHooks(of plan: AgentLaunchPlan) async throws {
    let hooks = try await ourHooks(for: plan)
    let edits: [[String: Any]] = hooks.filter { $0.trustStatus != "trusted" }.map { hook in
      [
        "keyPath": "hooks.state.\(Self.quotedKey(hook.key)).trusted_hash",
        "value": hook.currentHash,
        "mergeStrategy": "upsert",
      ]
    }
    guard !edits.isEmpty else { return }
    _ = try await connection.call(
      plan: plan, options: CodexActivityHooks.hookOptions(in: plan.arguments),
      method: "config/batchWrite",
      params: try JSONSerialization.data(withJSONObject: ["edits": edits]))
    // Believed only once Codex says so.
    guard try await ourHooks(for: plan).allSatisfy({ $0.trustStatus == "trusted" }) else {
      throw CodexHookTrustError.notApplied
    }
  }

  struct ListedHook {
    let key: String
    let command: String
    let currentHash: String
    let trustStatus: String
  }

  /// The hooks Codex lists for the plan's folder that came from its command line and run one of
  /// our commands, byte for byte. Nothing else is ever approved: not a hook of the user's, not one
  /// a cloned repository declares.
  func ourHooks(for plan: AgentLaunchPlan) async throws -> [ListedHook] {
    let answer = try await connection.call(
      plan: plan, options: CodexActivityHooks.hookOptions(in: plan.arguments),
      method: "hooks/list",
      params: try JSONSerialization.data(withJSONObject: ["cwds": [plan.workingDirectoryPath]]))
    guard let result = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
      let data = result["data"] as? [[String: Any]]
    else {
      throw CodexHookTrustError.unreadableAnswer
    }
    let commands = Set(CodexActivityHooks.commands)
    let listed = data.flatMap { entry in (entry["hooks"] as? [[String: Any]]) ?? [] }
      .compactMap { hook -> ListedHook? in
        guard hook["source"] as? String == "sessionFlags",
          let command = hook["command"] as? String, commands.contains(command),
          let key = hook["key"] as? String,
          let hash = hook["currentHash"] as? String,
          let status = hook["trustStatus"] as? String
        else { return nil }
        return ListedHook(key: key, command: command, currentHash: hash, trustStatus: status)
      }
    // A Codex that lists fewer of them than were passed does not know them all: approving the rest
    // would not make them run.
    guard listed.count == CodexActivityHooks.hooks.count else {
      throw CodexHookTrustError.unreadableAnswer
    }
    return listed
  }

  /// A key holds dots — `/<session-flags>/config.toml:stop:0:0` — so it is quoted as one
  /// component of the path, the way TOML quotes it.
  static func quotedKey(_ key: String) -> String {
    "\""
      + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"")
      + "\""
  }
}

public enum CodexHookTrustError: Error, Equatable, Sendable {
  case unreadableAnswer
  case notApplied
  case serverFailed(String)
  case timedOut
}

extension CodexAgentProvider: AgentHookTrusting {
  public func hookTrust(for plan: AgentLaunchPlan) async -> AgentHookTrust {
    await CodexHookTrust().hookTrust(for: plan)
  }

  public func trustHooks(of plan: AgentLaunchPlan) async throws {
    try await CodexHookTrust().trustHooks(of: plan)
  }
}

/// One JSON-RPC call to Codex's local server, started for it and stopped right after.
public protocol CodexAppServerConnecting: Sendable {
  /// The call's `result`, as the JSON the server sent. `params` is JSON too.
  func call(
    plan: AgentLaunchPlan, options: [String], method: String, params: Data
  ) async throws -> Data
}

/// `codex app-server`, over its standard input and output, with the plan's own executable,
/// environment — `CODEX_HOME` above all — and folder, so it reads the configuration the agent
/// will read. Started through `BoundedProcess`, like every command that is not a terminal: a group
/// of its own, a timeout, and nothing left behind.
public struct CodexAppServerProcess: CodexAppServerConnecting {
  private let timeout: Duration

  public init(timeout: Duration = .seconds(5)) {
    self.timeout = timeout
  }

  public func call(
    plan: AgentLaunchPlan, options: [String], method: String, params: Data
  ) async throws -> Data {
    // The server stops at the end of its input, before answering what is still in flight: the
    // input stays open until the answer to the call — the only request numbered 1 — has come.
    let messages: [[String: Any]] = [
      [
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": ["clientInfo": ["name": "vibe-manager", "version": "1"]],
      ],
      ["jsonrpc": "2.0", "method": "initialized"],
      [
        "jsonrpc": "2.0", "id": 1, "method": method,
        "params": try JSONSerialization.jsonObject(with: params),
      ],
    ]
    var input = Data()
    for message in messages {
      input += try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
    }
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: plan.executablePath, arguments: ["app-server"] + options,
        environment: plan.environment, workingDirectoryPath: plan.workingDirectoryPath,
        timeout: timeout,
        standardInput: BoundedProcessInput(
          data: input, closeOnceOutputContains: Data(#"{"id":1,"#.utf8))))
    guard !result.didTimeOut else { throw CodexHookTrustError.timedOut }
    return try Self.answer(in: result.standardOutput)
  }

  /// The `result` of the call, out of everything the server wrote.
  static func answer(in output: Data) throws -> Data {
    for line in output.split(separator: 0x0A) {
      guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
        message["id"] as? Int == 1
      else { continue }
      if let result = message["result"] {
        return try JSONSerialization.data(withJSONObject: result)
      }
      let error = (message["error"] as? [String: Any])?["message"] as? String ?? "error"
      throw CodexHookTrustError.serverFailed(error)
    }
    throw CodexHookTrustError.unreadableAnswer
  }
}
