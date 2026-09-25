import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// The real CLIs, signed in, over the network: opt in with `VIBE_SUMMARY_INTEGRATION=1`. Each run
/// costs a summary on the account of each agent.
@Suite(
  "Summaries written by the real CLIs",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_SUMMARY_INTEGRATION"] == "1"))
struct SummaryIntegrationTests {
  private let request = SummaryRequest(
    digest: """
      ## Turn 1
      User asked: Review https://gitlab.com/g/p/-/merge_requests/12 and fix the failing test
      Actions:
      - Bash: glab mr view 12
      - Edit: Sources/App.swift
      - Bash: swift test
      Agent said last: Fixed the failing test and left a note on the merge request.
      """,
    turnCount: 1, language: "fr-FR")

  @Test("Claude Code answers entries of the schema")
  func claudeCode() async throws {
    let entries = try await ClaudeCodeAgentProvider.make().sessionSummarizer().summarize(request)
    #expect(!entries.isEmpty)
    #expect(entries.allSatisfy { $0.turn == 1 })
  }

  @Test("Codex answers entries of the schema")
  func codex() async throws {
    let entries = try await CodexAgentProvider.make().sessionSummarizer().summarize(request)
    #expect(!entries.isEmpty)
  }
}
