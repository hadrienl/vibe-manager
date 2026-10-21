import Testing

@testable import VibeApplication

/// #409: a CLI updated on disk while its sessions still run the previous build.
struct AgentUpdateTests {
  @Test func claudeCodeVersionsAreTwoBuildsOfOneInstall() {
    let update = AgentUpdate.between(
      running: "/Users/me/.local/share/claude/versions/2.1.299",
      installed: "/Users/me/.local/share/claude/versions/2.1.303")
    #expect(update == AgentUpdate(runningVersion: "2.1.299", installedVersion: "2.1.303"))
  }

  @Test func codexReleasesAndHomebrewKegsToo() {
    #expect(
      AgentUpdate.between(
        running: "/Users/me/.codex/packages/standalone/releases/0.162.1-aarch64-apple-darwin/bin/codex",
        installed:
          "/Users/me/.codex/packages/standalone/releases/0.163.0-aarch64-apple-darwin/bin/codex")
        == AgentUpdate(runningVersion: "0.162.1", installedVersion: "0.163.0"))
    #expect(
      AgentUpdate.between(
        running: "/opt/homebrew/Cellar/codex/0.162.1/bin/codex",
        installed: "/opt/homebrew/Cellar/codex/0.163.0/bin/codex")
        == AgentUpdate(runningVersion: "0.162.1", installedVersion: "0.163.0"))
  }

  @Test func theSameBuildIsNoUpdate() {
    let path = "/Users/me/.local/share/claude/versions/2.1.303"
    #expect(AgentUpdate.between(running: path, installed: path) == nil)
  }

  /// npm's CLI runs under `node`: another file altogether, which says nothing of an update.
  @Test func anotherFileAltogetherIsNeverTakenForAnUpdate() {
    #expect(
      AgentUpdate.between(
        running: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
        installed: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js") == nil)
    #expect(
      AgentUpdate.between(
        running: "/Users/me/old/bin/claude", installed: "/Users/me/new/bin/claude") == nil)
  }

  // MARK: - Readiness

  private let idle = AgentActivityState(activity: .idle, source: .structured)

  private func screen(prompt: String = "", footer: String = "  ? for shortcuts") -> String {
    """
    ⏺ Done.

    ────────────────────────────────────────
    ❯ \(prompt)
    ────────────────────────────────────────
    \(footer)
    """
  }

  @Test func anIdleAgentWithNothingBehindItsPromptIsReady() {
    #expect(AgentUpdateRestartReadiness.isReady(activity: idle, screen: screen(), runsSubagents: false))
  }

  @Test func aWorkingAgentIsNot() {
    let working = AgentActivityState(activity: .working, source: .structured)
    #expect(
      !AgentUpdateRestartReadiness.isReady(activity: working, screen: screen(), runsSubagents: false))
    #expect(!AgentUpdateRestartReadiness.isReady(activity: nil, screen: screen(), runsSubagents: false))
  }

  @Test func textTypedIntoThePromptIsKept() {
    #expect(
      !AgentUpdateRestartReadiness.isReady(
        activity: idle, screen: screen(prompt: "fix the tests"), runsSubagents: false))
    #expect(
      AgentUpdateRestartReadiness.isReady(
        activity: idle, screen: screen(prompt: "Try \"fix lint errors\""), runsSubagents: false))
  }

  @Test func shellsAndAgentsInTheBackgroundAreWaitedFor() {
    #expect(
      !AgentUpdateRestartReadiness.isReady(
        activity: idle, screen: screen(footer: "  ▶▶ auto mode on · 2 shells · ← 1 agent"),
        runsSubagents: false))
    #expect(
      !AgentUpdateRestartReadiness.isReady(activity: idle, screen: screen(), runsSubagents: true))
  }

  /// Above the prompt is what the agent wrote, not its footer.
  @Test func wordsAboveThePromptAreNoFooter() {
    let screen = """
      ⏺ Started 2 shells and 1 agent earlier.

      ────────────────────────────────────────
      ❯ 
      ────────────────────────────────────────
        ? for shortcuts
      """
    #expect(!AgentUpdateRestartReadiness.runsInBackground(screen: screen))
  }

  /// Codex draws no rules: its prompt shows a hint while empty, and the text typed otherwise.
  @Test func codexPromptIsReadToo() {
    let empty = """
      • Done.

      › Ask a follow-up question

        gpt-5.5 high · ~/project
      """
    #expect(AgentUpdateRestartReadiness.isReady(activity: idle, screen: empty, runsSubagents: false))
    let typed = empty.replacingOccurrences(of: "Ask a follow-up question", with: "fix the tests")
    #expect(!AgentUpdateRestartReadiness.isReady(activity: idle, screen: typed, runsSubagents: false))
  }

  /// A prompt that cannot be read may hold what the user typed: it is not taken for empty.
  @Test func anUnrecognisedPromptIsNotReady() {
    #expect(
      !AgentUpdateRestartReadiness.isReady(
        activity: idle, screen: "Some panel\nwith no prompt", runsSubagents: false))
  }

  @Test func anUnreadableScreenIsNotReady() {
    #expect(!AgentUpdateRestartReadiness.isReady(activity: idle, screen: nil, runsSubagents: false))
  }
}
