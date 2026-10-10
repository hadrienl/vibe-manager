import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

@Suite("Handing the web view's tools to the CLIs")
struct AgentToolServerTests {
  private let server = AgentToolServer(
    name: "vibe-browser",
    executablePath: "/Applications/Vibe Manager.app/Contents/MacOS/Vibe Manager",
    arguments: ["--browser-bridge", "/var/folders/x/vibe-manager/ab/browser-v1.sock"])

  private func plan(_ arguments: [String]) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: ClaudeCodeAgentProvider.id, executablePath: "/usr/local/bin/claude",
      arguments: arguments, environment: ["PATH": "/usr/bin"], workingDirectoryPath: "/tmp",
      promptDelivery: .argument)
  }

  @Test("Claude Code gets one --mcp-config and the server's tools allowed, before the prompt")
  func claude() throws {
    let provider = ClaudeCodeAgentProvider.make(environment: ["HOME": "/Users/a"])
    let result = provider.providingTools(
      [server], to: plan(["--session-id", "x", "--", "-prompt starting with a dash"]))
    let arguments = result.arguments
    #expect(Array(arguments.suffix(2)) == ["--", "-prompt starting with a dash"])
    let index = try #require(arguments.firstIndex(of: "--mcp-config"))
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
    let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
    let entry = try #require(servers["vibe-browser"])
    #expect(entry["command"] as? String == server.executablePath)
    #expect(entry["args"] as? [String] == server.arguments)
    #expect(entry["type"] as? String == "stdio")
    #expect(arguments.contains("--allowedTools"))
    #expect(arguments.contains("mcp__vibe-browser"))
    #expect(!arguments.contains("--strict-mcp-config"))
  }

  @Test("Codex gets its servers as TOML overrides, quoted by hand, before the prompt")
  func codex() {
    let quoted = AgentToolServer(
      name: "vibe-browser", executablePath: #"/tmp/a "b"\c"#, arguments: ["x\ny"])
    let options = CodexToolOptions.options(for: [quoted])
    #expect(
      options == [
        "-c", #"mcp_servers.vibe-browser.command="/tmp/a \"b\"\\c""#,
        "-c", #"mcp_servers.vibe-browser.args=["x\ny"]"#,
      ])
    let provider = CodexAgentProvider.make(environment: [:])
    let result = provider.providingTools([server], to: plan(["resume", "id", "--", "prompt"]))
    #expect(result.arguments.first == "resume")
    #expect(Array(result.arguments.suffix(2)) == ["--", "prompt"])
    #expect(result.arguments.filter { $0 == "-c" }.count == 2)
  }

  @Test("No server, no change")
  func nothing() {
    let original = plan(["--session-id", "x"])
    #expect(
      ClaudeCodeAgentProvider.make(environment: [:]).providingTools([], to: original) == original)
  }
}

@Suite("Giving a coordinator its tools and instructions (#352)")
@MainActor
struct CoordinatorLaunchTests {
  private let coordinationServer = AgentToolServer(
    name: "vibe-sessions", executablePath: "/Applications/Vibe Manager.app/Contents/MacOS/Vibe",
    arguments: ["--browser-bridge", "/tmp/s.sock", "--server", "vibe-sessions"])

  private func plan(_ provider: AgentProviderID) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: provider, executablePath: "/usr/local/bin/agent",
      arguments: ["--", "Handle the V2 tickets."], environment: ["PATH": "/usr/bin"],
      workingDirectoryPath: "/tmp", promptDelivery: .argument)
  }

  private func provide(_ session: WorkSession, provider: AgentProviderID) async -> AgentLaunchPlan {
    let registry = AgentProviderRegistry(providers: [
      ClaudeCodeAgentProvider.make(environment: [:]), CodexAgentProvider.make(environment: [:]),
    ])
    let tools = ProvideAgentTools(
      agents: registry, setup: { nil }, coordination: { [coordinationServer] in coordinationServer }
    )
    return await tools(plan(provider), for: session)
  }

  @Test("Claude Code's coordinator gets the server, its tools allowed, and the instructions")
  func claude() async throws {
    let result = await provide(
      WorkSession(name: "V2", coordination: .coordinator), provider: ClaudeCodeAgentProvider.id)
    let arguments = result.arguments
    #expect(arguments.contains("mcp__vibe-sessions"))
    let index = try #require(arguments.firstIndex(of: "--append-system-prompt"))
    #expect(arguments[index + 1] == CoordinatorInstructions.text)
    #expect(Array(arguments.suffix(2)) == ["--", "Handle the V2 tickets."])
  }

  @Test("Codex's coordinator gets the server and developer instructions, as TOML")
  func codex() async {
    let result = await provide(
      WorkSession(name: "V2", coordination: .coordinator), provider: CodexAgentProvider.id)
    #expect(result.arguments.contains { $0.hasPrefix("mcp_servers.vibe-sessions.command=") })
    #expect(
      result.arguments.contains { $0.hasPrefix("developer_instructions=\"You are a coordinator") })
  }

  @Test("An ordinary session, or a child, gets neither")
  func others() async {
    for session in [
      WorkSession(name: "Alone"), WorkSession(name: "#351", coordination: .child(of: SessionID())),
    ] {
      let result = await provide(session, provider: ClaudeCodeAgentProvider.id)
      #expect(result.arguments == plan(ClaudeCodeAgentProvider.id).arguments)
    }
  }
}
