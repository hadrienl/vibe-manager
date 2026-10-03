import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

private func event(_ name: String, _ payload: String) -> AgentActivityEvent {
  AgentActivityEvent(name: name, date: Date(), payload: Data(payload.utf8))
}

private func notice(of signal: AgentSignal?) -> AgentRequestNotice? {
  guard case .questionAsked(_, _, let notice) = signal else { return nil }
  return notice
}

@Suite("An MCP server's elicitation, as Claude Code reports it (#273, P3)")
struct ElicitationReadingTests {
  /// What the documentation's example hands the hook, through the hook's own command.
  private func reported(mode: String, url: String) throws -> AgentActivityEvent {
    let log = try temporaryLog()
    let hook = try #require(
      ClaudeCodeActivityHooks.hooks.first { $0.event == "Elicitation" })
    _ = try runHook(
      AgentActivityHookCommand.command(event: hook.event, payload: hook.payload),
      input: """
        {"session_id":"abc","hook_event_name":"Elicitation","mcp_server_name":"memory",\
        "tool_name":"mcp__memory__create","message":"Please sign in",\
        "mode":"\(mode)","requested_schema":{"type":"object","properties":{"url":{"type":"string"}}},\
        "url":"\(url)","elicitation_id":"e1"}
        """,
      log: log)
    let line = try #require(lines(of: log).first)
    return event(line[0], line[2])
  }

  private func elicitation(_ event: AgentActivityEvent) -> AgentElicitation? {
    guard case .elicitation(let elicitation) = notice(of: ClaudeCodeSignalDecoder().signal(for: event))?
      .content
    else { return nil }
    return elicitation
  }

  @Test("A page to open keeps the server, its words and the address")
  func url() throws {
    let read = try #require(elicitation(try reported(mode: "url", url: "https://example.org/a?b=1")))
    #expect(read.server == "memory")
    #expect(read.message == "Please sign in")
    #expect(read.url == URL(string: "https://example.org/a?b=1"))
  }

  @Test("A form gives no page, even when an address comes with it")
  func form() throws {
    let read = try #require(elicitation(try reported(mode: "form", url: "https://example.org")))
    #expect(read.message == "Please sign in")
    #expect(read.url == nil)
  }

  @Test("Only a web page is ever opened")
  func schemes() {
    #expect(AgentElicitation(url: URL(string: "file:///etc/passwd")).url == nil)
    #expect(AgentElicitation(url: URL(string: "javascript:alert(1)")).url == nil)
    #expect(AgentElicitation(url: URL(string: "HTTP://example.org")).url != nil)
  }
}
