import Foundation
import VibeApplication

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
/// will read.
public struct CodexAppServerProcess: CodexAppServerConnecting {
  private let timeout: Duration

  public init(timeout: Duration = .seconds(5)) {
    self.timeout = timeout
  }

  public func call(
    plan: AgentLaunchPlan, options: [String], method: String, params: Data
  ) async throws -> Data {
    let request = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 1, "method": method,
      "params": try JSONSerialization.jsonObject(with: params),
    ])
    let session = CodexAppServerSession(
      executablePath: plan.executablePath, arguments: ["app-server"] + options,
      environment: plan.environment, workingDirectory: plan.workingDirectoryPath)
    return try await session.run(request: request, timeout: timeout)
  }
}

/// A server process for one call: `initialize`, the call, and the process is stopped.
final class CodexAppServerSession: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var buffer = Data()
  private var continuation: CheckedContinuation<Data, any Error>?
  private var sentCall = false
  private var callData = Data()

  init(
    executablePath: String, arguments: [String], environment: [String: String],
    workingDirectory: String
  ) {
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
  }

  func run(request: Data, timeout: Duration) async throws -> Data {
    callData = request
    defer { stop() }
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          self.start(continuation)
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw CodexHookTrustError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CodexHookTrustError.timedOut }
      return result
    }
  }

  private func start(_ continuation: CheckedContinuation<Data, any Error>) {
    lock.withLock { self.continuation = continuation }
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        self.finish(.failure(CodexHookTrustError.serverFailed("closed")))
      } else {
        self.received(data)
      }
    }
    do {
      try process.run()
      let initialize = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": ["clientInfo": ["name": "vibe-manager", "version": "1"]],
      ])
      write(initialize)
    } catch {
      finish(.failure(error))
    }
  }

  private func received(_ data: Data) {
    let lines: [Data] = lock.withLock {
      buffer.append(data)
      var lines: [Data] = []
      while let newline = buffer.firstIndex(of: 0x0A) {
        lines.append(Data(buffer[buffer.startIndex..<newline]))
        buffer = Data(buffer[(newline + 1)...])
      }
      return lines
    }
    for line in lines {
      guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let id = message["id"] as? Int
      else { continue }
      if id == 0 {
        let shouldSend = lock.withLock { () -> Bool in
          defer { sentCall = true }
          return !sentCall
        }
        guard shouldSend else { continue }
        if let initialized = try? JSONSerialization.data(withJSONObject: [
          "jsonrpc": "2.0", "method": "initialized",
        ]) {
          write(initialized)
        }
        write(callData)
      } else if id == 1 {
        if let result = message["result"],
          let data = try? JSONSerialization.data(withJSONObject: result)
        {
          finish(.success(data))
        } else {
          let error = (message["error"] as? [String: Any])?["message"] as? String ?? "error"
          finish(.failure(CodexHookTrustError.serverFailed(error)))
        }
      }
    }
  }

  private func write(_ data: Data) {
    try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
  }

  private func finish(_ result: Result<Data, any Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
  }

  private func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    finish(.failure(CancellationError()))
  }
}
