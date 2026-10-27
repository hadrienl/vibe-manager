import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Reasoning effort: arguments (#411)")
struct AgentEffortArgumentTests {
  private static let assigned = UUID(uuidString: "3f2b6c1e-8a4d-4f7b-9c2e-5d1a7b3c9e04")!

  private func claude(_ request: AgentLaunchRequest) throws -> [String] {
    try ClaudeCodeArgumentBuilder(makeIdentifier: { Self.assigned }).arguments(
      for: request, promptDelivery: .none, descriptor: ClaudeCodeAgentProvider.descriptor)
  }

  private func codex(_ request: AgentLaunchRequest) throws -> [String] {
    try CodexArgumentBuilder().arguments(
      for: request, promptDelivery: .none, descriptor: CodexAgentProvider.descriptor)
  }

  @Test("Claude Code is started with --effort, after its model")
  func claudeEffort() throws {
    let arguments = try claude(
      AgentLaunchRequest(workingDirectoryPath: "/tmp/app", modelID: "opus", effort: "xhigh"))
    #expect(
      arguments == [
        "--session-id", Self.assigned.uuidString.lowercased(), "--model", "opus", "--effort",
        "xhigh",
      ])
  }

  @Test("A resumed Claude Code conversation keeps its effort")
  func claudeResumeEffort() throws {
    let identifier = "0d6f3a8e-1c2b-4e5f-9a7b-3c4d5e6f7a8b"
    let arguments = try claude(
      AgentLaunchRequest(
        workingDirectoryPath: "/tmp/app", effort: "high", resume: .identifier(identifier)))
    #expect(arguments == ["--resume", identifier, "--effort", "high"])
  }

  @Test("Codex is given the setting of config.toml for this process, after the subcommand")
  func codexEffort() throws {
    let arguments = try codex(
      AgentLaunchRequest(
        workingDirectoryPath: "/tmp/app", modelID: "gpt-6", effort: "medium",
        resume: .identifier("rollout-id")))
    #expect(
      arguments == [
        "resume", "-m", "gpt-6", "-c", "model_reasoning_effort=medium", "-C", "/tmp/app", "--",
        "rollout-id",
      ])
  }

  @Test("No effort, nothing passed: the agent's own default applies")
  func noEffort() throws {
    #expect(try !claude(AgentLaunchRequest(workingDirectoryPath: "/tmp/app")).contains("--effort"))
    #expect(try !codex(AgentLaunchRequest(workingDirectoryPath: "/tmp/app")).contains("-c"))
  }

  @Test(
    "A malformed stored level is never passed",
    arguments: ["", "-high", "high low", "high\n", "High", "x=1", "\"high\"", "très"])
  func malformed(_ effort: String) throws {
    #expect(
      try !claude(AgentLaunchRequest(workingDirectoryPath: "/tmp/app", effort: effort))
        .contains("--effort"))
    #expect(
      try !codex(AgentLaunchRequest(workingDirectoryPath: "/tmp/app", effort: effort))
        .contains("-c"))
  }
}

@Suite("Reasoning effort: what Codex says (#411)")
struct CodexEffortReadingTests {
  private func line(_ type: String, _ payload: String) -> String {
    #"{"timestamp":"2026-10-21T09:21:32.488Z","type":"\#(type)","payload":\#(payload)}"#
  }

  @Test("The last turn_context of a rollout is the level in force")
  func lastTurnContext() throws {
    let rollout = [
      line("session_meta", #"{"id":"x","cwd":"/tmp"}"#),
      line(
        "turn_context", #"{"cwd":"/tmp","model":"gpt-6.1-sol","effort":"low","summary":"none"}"#),
      line("event_msg", #"{"type":"agent_message","message":"turn_context effort xhigh"}"#),
      line("turn_context", #"{"cwd":"/tmp","model":"gpt-6.1-sol","effort":"high"}"#),
      line("response_item", #"{"type":"message","content":"\"turn_context\""}"#),
    ].joined(separator: "\n")
    let report = CodexEffortReader.lastTurnContext(in: Data(rollout.utf8))
    #expect(report?.effort == "high")
    #expect(report?.modelID == "gpt-6.1-sol")
    #expect(report?.saidAt == Date(timeIntervalSince1970: 1_792_574_492.488))
  }

  @Test("A rollout is read from its end, across chunks, a line cut between two kept whole")
  func readsBackwards() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("effort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let filler = line(
      "response_item", #"{"type":"message","text":"\#(String(repeating: "a", count: 4000))"}"#)
    var lines = [line("turn_context", #"{"model":"gpt-6","effort":"low"}"#)]
    lines += Array(repeating: filler, count: 100)
    lines.append(line("turn_context", #"{"model":"gpt-6","effort":"xhigh"}"#))
    // Over a chunk of output after the last turn opened.
    lines += Array(repeating: filler, count: 100)
    let rollout = folder.appendingPathComponent("rollout.jsonl")
    try Data(lines.joined(separator: "\n").utf8).write(to: rollout)

    #expect(CodexEffortReader.lastTurnContext(of: rollout)?.effort == "xhigh")
  }

  @Test("Before the first turn, config.toml's top-level keys say the level")
  func configured() {
    let toml = """
      # mine
      model = "gpt-6.1-sol"
      model_reasoning_effort = "low"  # fast

      [profiles.deep]
      model_reasoning_effort = "xhigh"
      """
    #expect(
      CodexEffortReader.configuredReport(toml: toml)
        == AgentEffortReport(configuredEffort: "low", modelID: "gpt-6.1-sol"))
    #expect(CodexEffortReader.configuredReport(toml: "[x]\nmodel = \"a\"") == AgentEffortReport())
  }

  @Test("A conversation without a turn yet says nothing of its own, config.toml aside")
  func noTurnYet() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("effort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let config = folder.appendingPathComponent("config.toml")
    try Data(#"model_reasoning_effort = "medium""#.utf8).write(to: config)
    let reader = CodexEffortReader(
      configURL: config,
      locator: AgentTranscriptLocator(codexSessions: folder.appendingPathComponent("sessions")))
    #expect(
      reader.report(resumeIdentifier: "id", since: Date())
        == AgentEffortReport(configuredEffort: "medium"))
  }

  @Test("The model cache lists each model's levels")
  func catalogLevels() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("effort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cache = folder.appendingPathComponent("models_cache.json")
    try Data(
      #"""
      {"models":[
        {"slug":"gpt-6","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},
          {"effort":"max"},{"effort":"Bad level"}]},
        {"slug":"gpt-old","supported_reasoning_levels":"reshaped"}
      ]}
      """#.utf8
    ).write(to: cache)
    let catalog = CodexModelCatalog(cacheURL: cache)
    #expect(await catalog.effortLevels(modelID: "gpt-6") == ["low", "medium", "max"])
    #expect(await catalog.effortLevels(modelID: "gpt-old") == [])
    #expect(await catalog.models().map(\.id) == ["gpt-6", "gpt-old"])
  }

  @Test("A model listing a single level offers no choice: no menu, /model never driven")
  func singleLevel() {
    #expect(CodexAgentProvider.offeredLevels(["high"]) == [])
    #expect(CodexAgentProvider.offeredLevels(["low", "high"]) == ["low", "high"])
    #expect(CodexAgentProvider.offeredLevels([]) == CodexAgentProvider.fallbackEffortLevels)
  }
}

@Suite("Reasoning effort: the keys sent (#411)")
struct AgentEffortKeystrokeTests {
  @Test("Claude Code is typed /effort and the level, or default")
  func claudeCommand() throws {
    let provider = ClaudeCodeAgentProvider.make(environment: [:])
    guard case .command(let command) = provider.effortChange(to: "xhigh") else {
      Issue.record("not a command")
      return
    }
    #expect(command == "/effort xhigh")
    guard case .command(let reset) = provider.effortChange(to: nil) else {
      Issue.record("not a command")
      return
    }
    #expect(reset == "/effort default")
  }

  @Test("Codex opens /model, and has no default to go back to")
  func codexPanel() throws {
    let provider = CodexAgentProvider.make(environment: [:])
    guard case .panel(let opening, _) = provider.effortChange(to: "high") else {
      Issue.record("not a panel")
      return
    }
    #expect(opening == "/model")
    #expect(provider.effortChange(to: nil) == nil)
  }

  static let modelPanel = """
      >_ OpenAI Codex (v0.162.1)
    › /model

      Select Model and Effort
      1. GPT-6-Astra            Frontier intelligence for the most demanding work.
    › 2. GPT-6.1-Sol (current)  Latest workhorse model for coding and everyday work.
      3. GPT-6-Sol              Previous generation workhorse model.
      enter select · esc back
    """

  static func levelPanel(cursor: Int) -> String {
    let rows = [
      "1. Low (default) (current)  Fast responses with lighter reasoning",
      "2. Medium                   Balances speed and reasoning depth for everyday tasks",
      "3. High                     Greater reasoning depth for complex problems",
      "4. Extra high               Extra high reasoning depth for complex problems",
      "5. More reasoning…          Max and Ultra consume usage limits faster",
    ]
    return
      (["  Select Reasoning Level for GPT-6.1-Sol"]
      + rows.enumerated().map { ($0.offset + 1 == cursor ? "› " : "  ") + $0.element }
      + ["  enter default · s session · esc back"]).joined(separator: "\n")
  }

  @Test("The model in use is chosen again, with Return")
  func keepsModel() {
    #expect(CodexEffortPanel(level: "high").step(on: Self.modelPanel) == .press("\r"))
    let elsewhere = Self.modelPanel
      .replacingOccurrences(of: "› 2.", with: "  2.")
      .replacingOccurrences(of: "  1. GPT-6-Astra", with: "› 1. GPT-6-Astra")
    #expect(CodexEffortPanel(level: "high").step(on: elsewhere) == .press("\u{1B}[B"))
  }

  @Test("The level is reached by arrows and chosen for the session with s, never a digit")
  func choosesLevel() {
    let panel = CodexEffortPanel(level: "xhigh")
    #expect(panel.step(on: Self.levelPanel(cursor: 1)) == .press("\u{1B}[B\u{1B}[B\u{1B}[B"))
    #expect(panel.step(on: Self.levelPanel(cursor: 4)) == .finish("s"))
    #expect(
      CodexEffortPanel(level: "low").step(on: Self.levelPanel(cursor: 3))
        == .press(
          "\u{1B}[A\u{1B}[A"))
    #expect(CodexEffortPanel(level: "low").step(on: Self.levelPanel(cursor: 1)) == .finish("s"))
  }

  @Test("Max and Ultra are found behind More reasoning")
  func moreReasoning() {
    let panel = CodexEffortPanel(level: "max")
    #expect(panel.step(on: Self.levelPanel(cursor: 5)) == .press("\r"))
    // Its title, as codex-cli 0.163 names it.
    let more = """
        Advanced Reasoning
      › 1. Max     Maximum reasoning depth
        2. Ultra   The deepest reasoning
        enter default · s session · esc back
      """
    #expect(panel.step(on: more) == .finish("s"))
    #expect(CodexEffortPanel(level: "ultra").step(on: more) == .press("\u{1B}[B"))
  }

  @Test("From Max or Ultra, the cursor leaves More reasoning, whose footer offers no s")
  func fromAdvancedLevel() {
    let up = CodexEffortPanel.up
    #expect(
      CodexEffortPanel(level: "low").step(on: DialogScreens.codexLevelsUltraInForce)
        == .press(String(repeating: up, count: 4)))
    #expect(
      CodexEffortPanel(level: "high").step(on: DialogScreens.codexLevelsUltraInForce)
        == .press(String(repeating: up, count: 2)))
    #expect(
      CodexEffortPanel(level: "medium").step(on: DialogScreens.codexLevelsMaxInForceOnMedium)
        == .finish("s"))
    #expect(
      CodexEffortPanel(level: "max").step(on: DialogScreens.codexLevelsUltraInForce) == .press("\r")
    )
    #expect(
      CodexEffortPanel(level: "ultra").step(on: DialogScreens.codexAdvancedMaxInForce)
        == .press(CodexEffortPanel.down))
  }

  @Test("A panel without the choice of the session is never validated: Return writes config.toml")
  func olderFooter() {
    let older = Self.levelPanel(cursor: 3)
      .replacingOccurrences(
        of: "enter default · s session · esc back", with: "enter select · esc back")
    #expect(CodexEffortPanel(level: "high").step(on: older) == .wait)
  }

  @Test("Anything else is waited on: the prompt, or a panel not yet drawn")
  func waits() {
    #expect(CodexEffortPanel(level: "high").step(on: "› Ask Codex to do anything") == .wait)
  }
}
