import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Answers `hooks/list` from a list the test controls, and records every `config/batchWrite`.
private final class ScriptedCodexServer: CodexAppServerConnecting, @unchecked Sendable {
  private let lock = NSLock()
  private var hooks: [[String: Any]]
  private(set) var writes: [[[String: Any]]] = []
  var failsWith: (any Error)?
  /// Whether a write is taken into account: a Codex that ignores it leaves the hooks untrusted.
  var appliesWrites = true

  init(hooks: [[String: Any]]) {
    self.hooks = hooks
  }

  func call(
    plan: AgentLaunchPlan, options: [String], method: String, params: Data
  ) async throws -> Data {
    if let failsWith { throw failsWith }
    return try lock.withLock {
      switch method {
      case "hooks/list":
        return try JSONSerialization.data(withJSONObject: ["data": [["hooks": hooks]]])
      case "config/batchWrite":
        let object = try JSONSerialization.jsonObject(with: params) as? [String: Any]
        let edits = object?["edits"] as? [[String: Any]] ?? []
        writes.append(edits)
        if appliesWrites {
          hooks = hooks.map { hook in
            var hook = hook
            if edits.contains(where: {
              ($0["keyPath"] as? String)?.contains(hook["key"] as! String) == true
            }) {
              hook["trustStatus"] = "trusted"
            }
            return hook
          }
        }
        return try JSONSerialization.data(withJSONObject: ["status": "ok"])
      default:
        return Data("{}".utf8)
      }
    }
  }

  var recordedWrites: [[[String: Any]]] {
    lock.withLock { writes }
  }
}

private func listed(status: (Int) -> String = { _ in "untrusted" }) -> [[String: Any]] {
  CodexActivityHooks.commands.enumerated().map { index, command in
    [
      "key": "/<session-flags>/config.toml:event\(index):0:0", "command": command,
      "currentHash": "sha256:\(index)", "trustStatus": status(index), "source": "sessionFlags",
    ]
  }
}

private let plan = AgentLaunchPlan(
  providerID: CodexAgentProvider.id, executablePath: "/usr/local/bin/codex",
  arguments: CodexActivityHooks.options() + ["-C", "/Users/a/dev"], environment: [:],
  workingDirectoryPath: "/Users/a/dev", promptDelivery: .none)

@Suite("Approving Codex hooks")
struct CodexHookTrustTests {
  @Test("Hooks Codex already trusts need nothing")
  func alreadyTrusted() async {
    let server = ScriptedCodexServer(hooks: listed(status: { _ in "trusted" }))
    #expect(await CodexHookTrust(connection: server).hookTrust(for: plan) == .trusted)
  }

  @Test("Untrusted or modified hooks are shown by what they run")
  func needsApproval() async {
    let server = ScriptedCodexServer(hooks: listed(status: { $0 == 0 ? "modified" : "trusted" }))
    #expect(
      await CodexHookTrust(connection: server).hookTrust(for: plan)
        == .needsApproval(commands: [CodexActivityHooks.commands[0]]))
  }

  @Test("Approving writes our pending hooks, with the fingerprint Codex gave, and nothing else")
  func approvesOnlyOurs() async throws {
    var hooks = listed(status: { $0 == 1 ? "trusted" : "untrusted" })
    // The user's own hook, and one a cloned repository declares: never approved from here.
    hooks.append([
      "key": "/Users/a/.codex/hooks.json:stop:0:0", "command": "notify-me",
      "currentHash": "sha256:user", "trustStatus": "untrusted", "source": "user",
    ])
    hooks.append([
      "key": "/<session-flags>/config.toml:stop:1:0", "command": "curl evil.example",
      "currentHash": "sha256:evil", "trustStatus": "untrusted", "source": "sessionFlags",
    ])
    let server = ScriptedCodexServer(hooks: hooks)
    try await CodexHookTrust(connection: server).trustHooks(of: plan)

    let edits = try #require(server.recordedWrites.first)
    #expect(server.recordedWrites.count == 1)
    #expect(edits.count == CodexActivityHooks.hooks.count - 1)
    #expect(
      edits.first?["keyPath"] as? String
        == #"hooks.state."/<session-flags>/config.toml:event0:0:0".trusted_hash"#)
    #expect(edits.first?["value"] as? String == "sha256:0")
    #expect(edits.first?["mergeStrategy"] as? String == "upsert")
    let keys = edits.compactMap { $0["keyPath"] as? String }
    #expect(
      !keys.contains {
        $0.contains("hooks.json") || $0.contains("stop:1:0") || $0.contains("event1:")
      })
    #expect(await CodexHookTrust(connection: server).hookTrust(for: plan) == .trusted)
  }

  @Test("An approval Codex did not take is an error, not a success")
  func notApplied() async {
    let server = ScriptedCodexServer(hooks: listed())
    server.appliesWrites = false
    await #expect(throws: CodexHookTrustError.notApplied) {
      try await CodexHookTrust(connection: server).trustHooks(of: plan)
    }
  }

  @Test("A Codex that cannot be asked, or lists fewer hooks than it was given, is unknown")
  func unknown() async {
    let failing = ScriptedCodexServer(hooks: listed())
    failing.failsWith = CodexHookTrustError.timedOut
    #expect(await CodexHookTrust(connection: failing).hookTrust(for: plan) == .unknown)
    let partial = ScriptedCodexServer(hooks: Array(listed().dropLast()))
    #expect(await CodexHookTrust(connection: partial).hookTrust(for: plan) == .unknown)
  }

  @Test("A key is quoted as one component of the path, as TOML quotes it")
  func quotedKey() {
    #expect(
      CodexHookTrust.quotedKey("/<session-flags>/config.toml:stop:0:0")
        == #""/<session-flags>/config.toml:stop:0:0""#)
    #expect(CodexHookTrust.quotedKey(#"a"b\c"#) == #""a\"b\\c""#)
  }
}

/// Against the real `codex app-server`, in a `CODEX_HOME` of its own: the user's configuration is
/// never read nor written.
@Suite("Approving Codex hooks with the real CLI")
struct CodexHookTrustIntegrationTests {
  static let codex: String? = [
    "~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
  ]
  .map { NSString(string: $0).expandingTildeInPath }
  .first { FileManager.default.isExecutableFile(atPath: $0) }

  @Test(.enabled(if: codex != nil), .timeLimit(.minutes(1)))
  func approvesThroughTheServer() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let config = home.appendingPathComponent("config.toml")
    try Data("# kept as it is\nmodel = \"gpt-5\"\n".utf8).write(to: config)

    let plan = AgentLaunchPlan(
      providerID: CodexAgentProvider.id, executablePath: try #require(Self.codex),
      arguments: CodexActivityHooks.options() + ["-C", home.path],
      environment: [
        "CODEX_HOME": home.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
      ],
      workingDirectoryPath: home.path, promptDelivery: .none)
    let trust = CodexHookTrust(connection: CodexAppServerProcess(timeout: .seconds(20)))

    guard case .needsApproval(let commands) = await trust.hookTrust(for: plan) else {
      Issue.record("fresh hooks should need approval")
      return
    }
    #expect(Set(commands) == Set(CodexActivityHooks.commands))
    try await trust.trustHooks(of: plan)
    #expect(await trust.hookTrust(for: plan) == .trusted)
    let written = try String(contentsOf: config, encoding: .utf8)
    #expect(written.hasPrefix("# kept as it is\nmodel = \"gpt-5\""))
    #expect(written.contains("/<session-flags>/config.toml:stop:0:0"))
  }
}
