import Foundation
import Testing

@testable import VibeAgents

@Suite("Agent home directory resolution")
struct AgentHomeDirectoryTests {
  @Test("A tilde is expanded, an absolute path is kept, anything else resolves to nothing")
  func resolvesOverrides() {
    #expect(
      AgentHomeDirectory.resolvedOverride("~/elsewhere", home: "/Users/test")
        == "/Users/test/elsewhere")
    #expect(AgentHomeDirectory.resolvedOverride("~", home: "/Users/test") == "/Users/test")
    #expect(AgentHomeDirectory.resolvedOverride("/opt/state", home: "/Users/test") == "/opt/state")
    #expect(AgentHomeDirectory.resolvedOverride("relative/path", home: "/Users/test") == nil)
    #expect(AgentHomeDirectory.resolvedOverride("", home: "/Users/test") == nil)
    #expect(AgentHomeDirectory.resolvedOverride(nil, home: "/Users/test") == nil)
  }

  @Test("An unresolvable override is dropped rather than forwarded")
  func sanitizesOverrides() {
    let environment = ["HOME": "/Users/test", "CLAUDE_CONFIG_DIR": "relative"]
    let sanitized = AgentHomeDirectory.sanitized(
      overrideKey: "CLAUDE_CONFIG_DIR", environment: environment)

    // Forwarding a value the CLI reads differently would produce a session never found again.
    #expect(sanitized["CLAUDE_CONFIG_DIR"] == nil)
    #expect(sanitized["HOME"] == "/Users/test")
  }

  @Test("Both agents resolve their own directory from their own variable")
  func eachAgentKeepsItsOwnVariable() {
    let environment = [
      "HOME": "/Users/test",
      "CLAUDE_CONFIG_DIR": "~/claude-state",
      "CODEX_HOME": "~/codex-state",
    ]

    #expect(ClaudeCodeHome.directory(environment: environment).path == "/Users/test/claude-state")
    #expect(CodexHome.directory(environment: environment).path == "/Users/test/codex-state")
    #expect(
      ClaudeCodeHome.modelCatalogDirectory(environment: environment).path
        == "/Users/test/claude-state/cache/model-catalog"
    )
    #expect(
      ClaudeCodeHome.directory(environment: ["HOME": "/Users/test"]).path == "/Users/test/.claude")
  }
}
