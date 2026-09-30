import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// A folder of its own, deleted at the end.
private final class Folder {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentCommands-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  @discardableResult
  func write(_ text: String, to path: String) throws -> URL {
    let file = url.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    return file
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}

private func json(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object)
}

@Suite("Claude Code lists its skills and commands (#219)")
struct ClaudeCodeCommandListingTests {
  /// As 2.1.285 answers `initialize`, trimmed to one entry of each kind.
  nonisolated(unsafe) static let response: [String: Any] = [
    "commands": [
      ["name": "agent-reformulate", "description": "Send raw material.", "argumentHint": "[what]"],
      ["name": "saggar-cli", "description": "Drives saggar.", "argumentHint": ""],
      ["name": "export-conversation", "description": "Export Conversation to HTML (user)"],
      ["name": "deploy", "description": "Deploy the app (project)", "argumentHint": "<env>"],
      [
        "name": "prisme-ai:debug-events", "description": "(prisme-ai) Tracer une exécution.",
        "argumentHint": "", "aliases": ["debug-events"],
      ],
      [
        "name": "docs", "description": "Editable docs.", "argumentHint": "",
        "aliases": ["anthropic-skills:docs"],
      ],
      [
        "name": "code-review", "description": "Review the current diff.",
        "argumentHint": "[low|high]", "aliases": ["review"], "builtin": true,
      ],
      ["name": "dataviz", "description": "Charts."],
      [
        "name": "compact", "description": "Free up context.",
        "argumentHint": "<optional custom summarization instructions>", "builtin": true,
      ],
      ["name": "usage", "description": "Show usage.", "aliases": ["cost"], "builtin": true],
      ["name": "context", "description": "Show context usage", "builtin": true],
      ["name": "__remote-workflow", "description": "Server only.", "builtin": true],
      ["name": "workflow-launch-exec", "description": "Server only.", "builtin": true],
      ["name": "agents", "description": "(removed) Ask Claude.", "builtin": true],
      ["name": "extra-usage", "description": "Renamed to /usage-credits", "builtin": true],
      ["name": "compact", "description": "Twice."],
      ["description": "No name."],
    ]
  ]

  @Test("Each entry says what it is and where it comes from; the terminal's own are left out")
  func decoding() throws {
    let folder = try Folder()
    try folder.write("---\nname: saggar-cli\n---\n", to: "config/skills/saggar-cli/SKILL.md")
    try folder.write("x", to: "project/.claude/skills/agent-reformulate/SKILL.md")
    let list = try ClaudeCodeCommands.list(
      from: json(Self.response),
      workingDirectoryPath: folder.url.appendingPathComponent("project").path,
      configurationDirectory: folder.url.appendingPathComponent("config"))
    let commands = Dictionary(uniqueKeysWithValues: list.commands.map { ($0.name, $0) })
    #expect(
      list.commands.map(\.name) == [
        "agent-reformulate", "saggar-cli", "export-conversation", "deploy",
        "prisme-ai:debug-events", "docs", "code-review", "dataviz", "compact",
      ])
    #expect(commands["agent-reformulate"]?.origin == .project)
    #expect(commands["agent-reformulate"]?.argumentHint == "[what]")
    #expect(commands["saggar-cli"]?.origin == .user)
    #expect(commands["saggar-cli"]?.argumentHint == nil)
    #expect(commands["export-conversation"]?.kind == .command)
    #expect(commands["export-conversation"]?.origin == .user)
    #expect(commands["export-conversation"]?.description == "Export Conversation to HTML")
    #expect(commands["deploy"]?.origin == .project)
    #expect(commands["prisme-ai:debug-events"]?.origin == .plugin("prisme-ai"))
    #expect(commands["prisme-ai:debug-events"]?.description == "Tracer une exécution.")
    #expect(commands["prisme-ai:debug-events"]?.invocation == "/prisme-ai:debug-events")
    #expect(commands["docs"]?.origin == .plugin("anthropic-skills"))
    #expect(commands["docs"]?.aliases == [])
    #expect(commands["code-review"]?.kind == .command)
    #expect(commands["code-review"]?.origin == .builtin)
    #expect(commands["code-review"]?.aliases == ["review"])
    #expect(commands["dataviz"]?.kind == .skill)
    #expect(commands["dataviz"]?.origin == nil)
    #expect(commands["compact"]?.description == "Free up context.")
  }

  @Test("An answer the CLI did not give is an error")
  func unreadable() throws {
    #expect(throws: (any Error).self) {
      try ClaudeCodeCommands.list(
        from: Data("[]".utf8), workingDirectoryPath: "/tmp",
        configurationDirectory: URL(fileURLWithPath: "/tmp"))
    }
    #expect(throws: ClaudeCodeCommandError.failed("nope")) {
      try ClaudeCodeCommandProcess.answer(
        in: Data(
          #"{"type":"control_response","response":{"subtype":"error","error":"nope"}}"#.utf8))
    }
    #expect(throws: ClaudeCodeCommandError.unreadableAnswer) {
      try ClaudeCodeCommandProcess.answer(in: Data("{\"type\":\"system\"}\nnot json\n".utf8))
    }
  }

  @Test("The CLI is asked over stream-json, without its hooks and without writing a transcript")
  func process() async throws {
    let folder = try Folder()
    // Stands for `claude`: records its arguments, answers the request once it read it, then
    // leaves at the end of its input.
    let script = try folder.write(
      """
      #!/bin/sh
      printf '%s\\n' "$@" > "\(folder.url.path)/arguments"
      printf '%s\\n' '{"type":"system","subtype":"hook_started"}'
      read -r request
      printf '%s\\n' "$request" > "\(folder.url.path)/request"
      printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"vibe-commands","response":{"commands":[{"name":"compact","description":"Free up context.","builtin":true}]}}}'
      cat > /dev/null
      """, to: "claude")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path)
    let plan = AgentLaunchPlan(
      providerID: ClaudeCodeAgentProvider.id, executablePath: script.path, arguments: [],
      environment: ["PATH": "/usr/bin:/bin"], workingDirectoryPath: folder.url.path,
      promptDelivery: .none)
    let response = try await ClaudeCodeCommandProcess(timeout: .seconds(20))
      .initializeResponse(plan: plan)
    let list = try ClaudeCodeCommands.list(
      from: response, workingDirectoryPath: folder.url.path,
      configurationDirectory: folder.url)
    #expect(list.commands.map(\.invocation) == ["/compact"])
    let arguments = try String(
      contentsOf: folder.url.appendingPathComponent("arguments"), encoding: .utf8)
    #expect(arguments.split(separator: "\n").map(String.init) == ClaudeCodeCommandProcess.arguments)
    #expect(arguments.contains(#"{"disableAllHooks":true}"#))
    #expect(arguments.contains("--no-session-persistence"))
    let request = try String(
      contentsOf: folder.url.appendingPathComponent("request"), encoding: .utf8)
    #expect(request.contains(#""subtype":"initialize""#))
  }
}

@Suite("Codex lists its skills, prompts and commands (#219)")
struct CodexCommandListingTests {
  /// As `skills/list` of 0.159.2 answers, trimmed.
  nonisolated(unsafe) static let result: [String: Any] = [
    "data": [
      [
        "cwd": "/Users/a/dev",
        "skills": [
          [
            "name": "prisme-ai:debug-events", "description": "Tracer une exécution.",
            "scope": "user", "pluginId": "prisme-ai@prismeai-mcp", "enabled": true,
            "path": "/p/SKILL.md",
          ],
          [
            "name": "imagegen", "description": "Generate or edit raster images when…",
            "shortDescription": "Generate images", "scope": "system", "enabled": true,
            "path": "/s/SKILL.md",
          ],
          [
            "name": "local", "description": "A skill of the repository.", "scope": "repo",
            "enabled": true, "path": "/r/SKILL.md",
            "interface": ["shortDescription": "Repository skill"],
          ],
          [
            "name": "off", "description": "Disabled.", "scope": "user", "enabled": false,
            "path": "/o/SKILL.md",
          ],
          [
            "name": "saggar-cli", "description": "Drive saggar.", "scope": "user",
            "enabled": true, "path": "/u/SKILL.md",
          ],
        ],
        "errors": [["path": "/broken/SKILL.md", "message": "missing field `description`"]],
      ]
    ]
  ]

  @Test("Skills go by `$`, from where Codex says; a skill it could not read is a problem")
  func skills() throws {
    let list = try CodexCommands.skills(from: json(Self.result))
    #expect(
      list.commands.map(\.invocation) == [
        "$prisme-ai:debug-events", "$imagegen", "$local", "$saggar-cli",
      ])
    #expect(
      list.commands.map(\.origin) == [.plugin("prisme-ai"), .system, .project, .user])
    #expect(
      list.commands.map(\.description) == [
        "Tracer une exécution.", "Generate images", "Repository skill", "Drive saggar.",
      ])
    #expect(list.commands.allSatisfy { $0.kind == .skill })
    #expect(
      list.problems == [
        AgentCommandProblem(path: "/broken/SKILL.md", message: "missing field `description`")
      ])
    #expect(throws: CodexCommands.Error.unreadableAnswer) {
      try CodexCommands.skills(from: Data("{}".utf8))
    }
  }

  @Test("Prompts are read from the folder when there is one; a broken one is left out")
  func prompts() throws {
    let folder = try Folder()
    #expect(CodexCommands.prompts(in: folder.url).commands.isEmpty)
    try folder.write(
      "---\ndescription: \"Draft a pull request\"\nargument-hint: [BRANCH]\n---\nBody\n",
      to: "prompts/draftpr.md")
    try folder.write("# Explain the code\n\nMore.", to: "prompts/explain.md")
    try folder.write("---\ndescription: never closed\n", to: "prompts/broken.md")
    try folder.write("not a prompt", to: "prompts/notes.txt")
    let list = CodexCommands.prompts(in: folder.url)
    #expect(list.commands.map(\.invocation) == ["/prompts:draftpr", "/prompts:explain"])
    #expect(list.commands.map(\.description) == ["Draft a pull request", "Explain the code"])
    #expect(list.commands.first?.argumentHint == "[BRANCH]")
    #expect(list.commands.allSatisfy { $0.kind == .command && $0.origin == .user })
    #expect(list.problems.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["broken.md"])
  }

  private final class Server: CodexAppServerConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String: Any])] = []
    var calls: [(String, [String: Any])] { lock.withLock { _calls } }

    func call(plan: AgentLaunchPlan, options: [String], method: String, params: Data)
      async throws -> Data
    {
      let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] ?? [:]
      lock.withLock { _calls.append((method, object)) }
      return try json(CodexCommandListingTests.result)
    }
  }

  @Test("The provider asks for the session's folder, and adds its prompts and own commands")
  func provider() async throws {
    let folder = try Folder()
    try folder.write("---\ndescription: Hi\n---\n", to: "codex/prompts/hello.md")
    let server = Server()
    let environment = [
      "PATH": "/usr/bin", "HOME": folder.url.path,
      "CODEX_HOME": folder.url.appendingPathComponent("codex").path,
    ]
    let provider = CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: CodexAgentProvider.descriptor,
        specification: CodexAgentProvider.specification,
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: CodexAgentProvider.descriptor,
          specification: CodexAgentProvider.specification,
          locator: StubLocator(
            location: .found(path: "/usr/local/bin/codex", source: .candidateDirectory)),
          probe: StubProcessProbe(
            defaultResponse: .success(
              ProbeResult(exitCode: 0, standardOutput: "codex-cli 0.159.2"))),
          environment: environment, now: { Date(timeIntervalSince1970: 0) }),
        environment: environment),
      catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models.json")),
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")),
      appServer: server)
    let list = try await provider.commands(inWorkingDirectory: "/Users/a/dev", refresh: true)
    #expect(server.calls.map(\.0) == ["skills/list"])
    #expect(server.calls.first?.1["cwds"] as? [String] == ["/Users/a/dev"])
    #expect(server.calls.first?.1["forceReload"] as? Bool == true)
    #expect(list.commands.map(\.invocation).contains("/prompts:hello"))
    #expect(list.commands.suffix(2).map(\.invocation) == ["/compact", "/init"])
    #expect(list.problems.count == 1)
  }
}
