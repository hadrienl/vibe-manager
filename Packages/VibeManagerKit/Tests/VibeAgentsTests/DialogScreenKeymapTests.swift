import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Screens as Claude Code 2.1.285 and codex-cli 0.159.2 drew them in a pty (#273), their paths
/// replaced.
enum DialogScreens {
  static let claudePlanAutoMode = """
    ⏺ Plan ready
     Claude has written up a plan and is ready to execute. Would you like to proceed?
     ❯ 1. Yes, and use auto mode
       2. Yes, manually approve edits
       3. Tell Claude what to change
          shift+tab to approve with this feedback
     ctrl+g to edit in VS Code · ~/.claude/plans/plan.md
    """
  static let claudePlanEdits = """
     Claude has written up a plan and is ready to execute. Would you like to proceed?
     ❯ 1. Yes, auto-accept edits
       2. Yes, manually approve edits
       3. Tell Claude what to change
          shift+tab to approve with this feedback
     ctrl+g to edit in VS Code · ~/.claude/plans/plan.md
    """
  static let claudePlanClearContext = """
     ❯ 1. Yes, clear context and auto-accept edits
       2. Yes, auto-accept edits
       3. Yes, manually approve edits
       4. Tell Claude what to change
    """
  static let claudeBash = """
     Bash command
       touch made-by-bash.txt
       Create empty file made-by-bash.txt
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and always allow access to /Users/a/proj
          from this project
       3. Yes, and switch to auto mode · auto mode handles these prompts for you
       4. No
     Esc to cancel · Tab to amend
    """
  static let claudeNetwork = """
     Network request outside of sandbox
       Host: example.org
       Do you want to allow this connection?
       ❯ 1. Yes
         2. Yes, and don't ask again for example.org
         3. No, and tell Claude what to do differently (esc)
    """
  static let codexCommand = """
    • Running touch made-by-codex.txt
      Would you like to run the following command?
      Reason: Allow creating the requested made-by-codex.txt file?
      $ touch made-by-codex.txt
    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `touch made-by-codex.txt` (p)
      3. No, and tell Codex what to do differently (esc)
      Press enter to confirm or esc to cancel
    """
  /// From `tui/src/bottom_pane/approval_overlay.rs` in 0.159: the dialog of a network access.
  static let codexNetwork = """
      Do you want to allow network access to example.org?
    › 1. Yes, just this once (y)
      2. Yes, and allow this host for this conversation (a)
      3. Yes, and allow this host in the future (p)
      4. No, and block this host in the future (d)
      5. No, and tell Codex what to do differently (esc)
      Press enter to confirm or esc to cancel
    """
  /// From `tui/src/bottom_pane/snapshots` in 0.159: an MCP tool's approval, a form.
  static let codexMCPTool = """
      Field 1/1
      Allow this request?
      › 1. Allow                   Run the tool and continue
        2. Allow for this session  Run the tool and remember this choice for this session
        3. Always allow            Run the tool and remember this choice for future tool calls
        4. Cancel                  Cancel this tool call






      enter to submit | esc to cancel
    """
  /// An agent's own numbered list, the prompt back under it: no dialog.
  static let agentList = """
    ⏺ Two ways:
      1. Yes, rebuild
      2. No
    ────────
    ❯
    ────────
    """

  static func dialog(_ text: String) -> AgentDialogScreen? { AgentDialogScreen(screen: text) }
}

@Suite("Reading a dialog off the screen (#273)")
struct AgentDialogScreenTests {
  @Test("Its options, wrapped labels joined, Codex's keys apart")
  func options() throws {
    let bash = try #require(DialogScreens.dialog(DialogScreens.claudeBash))
    #expect(bash.options.map(\.number) == [1, 2, 3, 4])
    #expect(bash.options[1].label == "Yes, and always allow access to /Users/a/proj from this project")
    let codex = try #require(DialogScreens.dialog(DialogScreens.codexCommand))
    #expect(codex.options.map(\.shortcut) == ["y", "p", "esc"])
    #expect(codex.options[0].label == "Yes, proceed")
  }

  @Test("An agent's numbered list, or nothing numbered, is no dialog")
  func none() {
    #expect(DialogScreens.dialog(DialogScreens.agentList) == nil)
    #expect(DialogScreens.dialog("❯ ") == nil)
    #expect(DialogScreens.dialog("") == nil)
  }
}

@Suite("Keys read off the dialog on screen (#273)")
struct DialogScreenKeymapTests {
  let claude = ClaudeCodeAnswerKeymap()
  let codex = CodexAnswerKeymap()

  private func permission(
    _ tool: AgentToolPermission.Tool = .shell, purpose: String? = nil,
    always: AgentAlwaysAllow? = AgentAlwaysAllow(rules: [.commandPrefix], scope: .session)
  ) -> AgentRequestContent {
    .permission(
      AgentToolPermission(
        tool: tool, toolName: "Bash", subject: "ls", purpose: purpose, alwaysAllow: always))
  }

  @Test("Claude Code's plan: each approval takes its own option, wherever it stands")
  func claudePlan() {
    let plan = AgentRequestContent.plan(excerpt: "Do it", isComplete: true)
    func keys(_ approval: AgentPlanApproval, _ screen: String) -> [[UInt8]]? {
      claude.keystrokes(
        for: .approvePlan(approval), to: plan, screen: DialogScreens.dialog(screen))
    }
    #expect(keys(.acceptEdits, DialogScreens.claudePlanEdits) == [Array("1".utf8)])
    #expect(keys(.reviewEdits, DialogScreens.claudePlanEdits) == [Array("2".utf8)])
    // With the model's auto mode available, `1` is that mode: accepting edits is not offered.
    #expect(keys(.acceptEdits, DialogScreens.claudePlanAutoMode) == nil)
    #expect(keys(.autoMode, DialogScreens.claudePlanAutoMode) == [Array("1".utf8)])
    #expect(keys(.autoMode, DialogScreens.claudePlanEdits) == nil)
    // Never the options that also clear the context.
    #expect(keys(.acceptEdits, DialogScreens.claudePlanClearContext) == [Array("2".utf8)])
    #expect(keys(.reviewEdits, DialogScreens.claudePlanClearContext) == [Array("3".utf8)])
    #expect(
      claude.keystrokes(for: .rejectPlan, to: plan, screen: nil) == [TerminalKeys.escape])
  }

  @Test("Claude Code's permission: never the option that switches to auto mode")
  func claudePermission() {
    let content = permission()
    let bash = DialogScreens.dialog(DialogScreens.claudeBash)
    #expect(claude.keystrokes(for: .allowOnce, to: content, screen: bash) == [Array("1".utf8)])
    #expect(claude.keystrokes(for: .allowAlways, to: content, screen: bash) == [Array("2".utf8)])
    let modeOnly = DialogScreens.dialog(
      """
       ❯ 1. Yes
         2. Yes, and switch to auto mode · auto mode handles these prompts for you
         3. No
      """)
    #expect(claude.keystrokes(for: .allowAlways, to: content, screen: modeOnly) == nil)
    // Unread, nothing but Escape is typed.
    #expect(claude.keystrokes(for: .allowOnce, to: content, screen: nil) == nil)
    #expect(claude.keystrokes(for: .deny, to: content, screen: nil) == [TerminalKeys.escape])
  }

  @Test("Codex: the keys each option shows, and never a host allowed for good")
  func codexKeys() {
    let content = permission()
    let command = DialogScreens.dialog(DialogScreens.codexCommand)
    #expect(codex.keystrokes(for: .allowOnce, to: content, screen: command) == [Array("y".utf8)])
    #expect(codex.keystrokes(for: .allowAlways, to: content, screen: command) == [Array("p".utf8)])
    let withoutPrefix = DialogScreens.dialog(
      """
      › 1. Yes, proceed (y)
        2. No, and tell Codex what to do differently (esc)
      """)
    #expect(codex.keystrokes(for: .allowAlways, to: content, screen: withoutPrefix) == nil)
    let network = DialogScreens.dialog(DialogScreens.codexNetwork)
    #expect(codex.keystrokes(for: .allowAlways, to: content, screen: network) == nil)
    #expect(codex.keystrokes(for: .allowOnce, to: content, screen: nil) == nil)
    #expect(codex.keystrokes(for: .deny, to: content, screen: nil) == [TerminalKeys.escape])
  }

  @Test("Codex: a network access offers no Always, whose words would describe commands")
  func codexNetworkRequest() {
    let event = AgentActivityEvent(
      name: "PermissionRequest", date: Date(),
      payload: Data(
        #"{"tool_name":"Bash","tool_input":{"command":"curl example.org","description":"network-access example.org"}}"#
          .utf8))
    guard case .questionAsked(_, _, let notice?) = CodexSignalDecoder().signal(for: event),
      case .permission(let permission) = notice.content
    else {
      Issue.record("not a permission")
      return
    }
    #expect(permission.alwaysAllow == nil)
    #expect(!codex.answers(for: notice.content).contains(.allowAlways))
  }
}
