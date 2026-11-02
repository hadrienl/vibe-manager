import Testing

@testable import VibeDomain

@Suite("An extra account of an agent")
struct AgentAccountTests {
  private let home = "/Users/someone"

  private func account(_ directory: String, harness: EndpointHarness = .claudeCode, name: String = "Perso")
    -> AgentAccount
  {
    AgentAccount(name: name, harness: harness, configurationDirectory: directory)
  }

  @Test("A tilde and a trailing slash are the same folder; a relative path is refused")
  func paths() {
    #expect(AgentAccount.resolvedDirectory("~/.claude-2/", home: home) == "/Users/someone/.claude-2")
    #expect(AgentAccount.resolvedDirectory("/a/b", home: home) == "/a/b")
    #expect(AgentAccount.resolvedDirectory(".claude-2", home: home) == nil)
    #expect(AgentAccount.resolvedDirectory("/", home: home) == nil)
    #expect(account("x").validationIssues(among: [], home: home) == [.directoryNotAbsolute])
  }

  @Test("The agent's own folder, and another account's of the same CLI, are refused")
  func sameFolder() {
    #expect(account("~/.claude/").validationIssues(among: [], home: home) == [.directoryIsDefault])
    #expect(account("~/.codex", harness: .codex).validationIssues(among: [], home: home) == [.directoryIsDefault])
    let other = account("/Users/someone/.two", name: "Two")
    #expect(account("~/.two").validationIssues(among: [other], home: home) == [.directoryTaken(name: "Two")])
    // Another CLI's folder is its own business, and an account does not conflict with itself.
    #expect(account("~/.two", harness: .codex).validationIssues(among: [other], home: home).isEmpty)
    #expect(other.validationIssues(among: [other], home: home).isEmpty)
  }

  @Test("A name is required")
  func name() {
    #expect(account("~/.two", name: "  ").validationIssues(among: [], home: home) == [.noName])
  }
}
