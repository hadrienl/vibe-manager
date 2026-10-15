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

  /// An MCP server's form with nothing to fill in, as Claude Code 2.1.288 draws it, wrapped in a
  /// narrow pane.
  static let claudeConfirmation = """
     Calling Supabase 4 times… (ctrl+o to expand)
     ⎿  Fulfilling input required by 'tools/call' (round 1)

    ──────────────────────────────────────────────────────────
     MCP server “claude.ai Supabase” requests your input

     This SQL includes destructive operations (DROP, DELETE,
     TRUNCATE or UPDATE without WHERE).
     It may permanently remove data, tables, schemas or other objects.
     Run it on project msrauwqwfahxpgwrhmlb?

     ❯ Accept    Decline

     Esc to cancel · ↑/↓ to navigate
    """
  static let confirmationMessage = """
    This SQL includes destructive operations (DROP, DELETE, TRUNCATE or UPDATE without WHERE).
    It may permanently remove data, tables, schemas or other objects.
    Run it on project msrauwqwfahxpgwrhmlb?
    """

  /// The update Codex 0.159.2 offers as it starts.
  static let codexUpdate = """
      Update available · 0.159.2 → 0.162.1
      Release notes: https://github.com/openai/codex/releases/latest

    › 1. Update now (runs `sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'`)
      2. Skip
      3. Skip until next version

      enter continue · esc skip
    """
  /// Codex 0.159.2 resumed, at its prompt: no hook has spoken yet, and none will before a turn.
  static let codexAtRest = """
    • CI corrigée et verte sur la PR #373.

      Worked for 32m 33s • Oct 12 at 14:47

    › Ask Codex to do anything

      GPT-5.6-Sol medium · ~/Documents/vibe-manager
      ? for shortcuts                                        ⚠ 4 warnings · f2 to view
    """
  /// The folder's trust, as Claude Code 2.1.300 asks it before anything else: no digit.
  static let claudeTrust = """
    ────────────────────────────────────────────────────────────────
     Accessing workspace:

     /Users/hadrien/Documents/prisme.ai/.worktrees/oauth-failure-de
     sign

     Quick safety check: Is this a project you created or one you trust? (Like your own code, a
     well-known open source project, or work from your team).

     Claude Code'll be able to read, edit, and execute files here.

     Security guide

     ❯ No, exit
       Yes, I trust this folder

     Enter to confirm · Esc to cancel
    """
  /// Two questions, as Claude Code 2.1.296 draws the first: "Chat about this" past a rule.
  static let claudeChatAboutThis = """
    ←  ☐ Color  ☐ Pets  ✔ Submit  →

    Pick a color?

    ❯ 1. Red
         Rouge
      2. Blue
         Bleu
      3. Type something.
    ──────────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

  static func dialog(_ text: String) -> AgentDialogScreen? { AgentDialogScreen(screen: text) }
}

@Suite("Reading a dialog off the screen (#273)")
struct AgentDialogScreenTests {
  @Test("Its options, wrapped labels joined, Codex's keys apart")
  func options() throws {
    let bash = try #require(DialogScreens.dialog(DialogScreens.claudeBash))
    #expect(bash.options.map(\.number) == [1, 2, 3, 4])
    #expect(
      bash.options[1].label == "Yes, and always allow access to /Users/a/proj from this project")
    let codex = try #require(DialogScreens.dialog(DialogScreens.codexCommand))
    #expect(codex.options.map(\.shortcut) == ["y", "p", "esc"])
    #expect(codex.options[0].label == "Yes, proceed")
  }

  @Test("A label wrapped over several lines, in a narrow pane, keeps the options in one dialog")
  func wrapped() throws {
    let narrow = try #require(
      DialogScreens.dialog(
        """
         ❯ 1. Yes
           2. Yes, and always allow access to
              /Users/a/a-rather-long/path/to/a
              project from this project
           3. No
        """))
    #expect(narrow.options.map(\.number) == [1, 2, 3])
    #expect(narrow.options[1].label.hasSuffix("project from this project"))
  }

  @Test("A confirmation: its server, its words, and whether Accept is pointed at")
  func confirmation() throws {
    let screen = try #require(DialogScreens.dialog(DialogScreens.claudeConfirmation))
    #expect(screen.options.isEmpty)
    let form = try #require(screen.confirmation)
    #expect(form.server == "claude.ai Supabase")
    #expect(form.isAcceptPointed)
    let elicitation = AgentElicitation(
      server: "claude.ai Supabase", message: DialogScreens.confirmationMessage, fieldCount: 0)
    #expect(form.asks(elicitation))
    #expect(
      !form.asks(
        AgentElicitation(
          server: "claude.ai Supabase", message: "Run it on another project?", fieldCount: 0)))
    #expect(
      !form.asks(
        AgentElicitation(server: "other", message: DialogScreens.confirmationMessage, fieldCount: 0)
      ))
    let declining = DialogScreens.claudeConfirmation.replacingOccurrences(
      of: "❯ Accept    Decline", with: "  Accept  ❯ Decline")
    #expect(DialogScreens.dialog(declining)?.confirmation?.isAcceptPointed == false)
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

  @Test("Claude Code's confirmation: Return once Accept is pointed at under its words, Escape")
  func claudeConfirmation() {
    let elicitation = AgentRequestContent.elicitation(
      AgentElicitation(
        server: "claude.ai Supabase", message: DialogScreens.confirmationMessage, fieldCount: 0))
    let screen = DialogScreens.dialog(DialogScreens.claudeConfirmation)
    #expect(claude.keystrokes(for: .allowOnce, to: elicitation, screen: screen) == [[0x0D]])
    #expect(claude.keystrokes(for: .deny, to: elicitation, screen: screen) == [[0x1B]])
    // Not drawn yet: a key would land in the prompt, and Escape stop the turn.
    #expect(claude.keystrokes(for: .allowOnce, to: elicitation, screen: nil) == nil)
    #expect(claude.keystrokes(for: .deny, to: elicitation, screen: nil) == nil)
    // Decline pointed at: Return would decline.
    let declining = DialogScreens.dialog(
      DialogScreens.claudeConfirmation.replacingOccurrences(
        of: "❯ Accept    Decline", with: "  Accept  ❯ Decline"))
    #expect(claude.keystrokes(for: .allowOnce, to: elicitation, screen: declining) == nil)
    // A form with fields to fill in, drawn or not, is left to the terminal.
    let form = AgentRequestContent.elicitation(
      AgentElicitation(
        server: "claude.ai Supabase", message: DialogScreens.confirmationMessage, fieldCount: 1))
    #expect(claude.keystrokes(for: .allowOnce, to: form, screen: screen) == nil)
  }

  @Test("Codex's update, read off the screen: Skip takes 2, Skip This Version 3, never Update")
  func codexUpdate() throws {
    let prompt = try #require(codex.startupDialog(onScreen: DialogScreens.codexUpdate))
    #expect(prompt == AgentTerminalPrompt(kind: .update, message: "0.159.2 → 0.162.1"))
    #expect(codex.drawnDialog(onScreen: DialogScreens.codexUpdate) == AgentDrawnDialog(.update))
    let update = AgentRequestContent.inTerminal(prompt)
    #expect(codex.answers(for: update) == [.skipUpdate])
    let screen = DialogScreens.dialog(DialogScreens.codexUpdate)
    #expect(
      codex.keystrokes(for: .skipUpdate(untilNextVersion: false), to: update, screen: screen)
        == [[0x32]])
    #expect(
      codex.keystrokes(for: .skipUpdate(untilNextVersion: true), to: update, screen: screen)
        == [[0x33]])
    #expect(codex.keystrokes(for: .skipUpdate(untilNextVersion: false), to: update) == nil)
    // Another dialog of the start is not taken for it.
    #expect(codex.startupDialog(onScreen: DialogScreens.codexCommand) == nil)
    #expect(
      codex.answers(for: .inTerminal(AgentTerminalPrompt(kind: .startup, message: nil))).isEmpty)
  }

  @Test("Codex's prompt at rest: no dialog of its start waits; a dialog's pointer is not it")
  func codexPromptAtRest() {
    #expect(codex.showsPromptAtRest(onScreen: DialogScreens.codexAtRest))
    #expect(codex.startupDialog(onScreen: DialogScreens.codexAtRest) == nil)
    #expect(!codex.showsPromptAtRest(onScreen: DialogScreens.codexUpdate))
    #expect(!codex.showsPromptAtRest(onScreen: DialogScreens.codexCommand))
    #expect(!claude.showsPromptAtRest(onScreen: DialogScreens.codexAtRest))
    // The folder's trust, a panel: no prompt under them.
    let trust = """
      Do you trust the contents of this directory?

      › 1. Yes, continue
        2. No, quit

        Press enter to continue
      """
    #expect(!codex.showsPromptAtRest(onScreen: trust))
    let panel = """
      Select Model and Effort
      › gpt-5.6-sol (current)
        gpt-5.5

        enter select · esc back
      """
    #expect(!codex.showsPromptAtRest(onScreen: panel))
  }

  @Test("Claude Code's folder trust, read off the screen: the down arrow, then Return")
  func claudeTrust() throws {
    let folder = "/Users/hadrien/Documents/prisme.ai/.worktrees/oauth-failure-design"
    let prompt = try #require(claude.startupDialog(onScreen: DialogScreens.claudeTrust))
    #expect(prompt == AgentTerminalPrompt(kind: .trust, message: folder))
    let trust = AgentRequestContent.inTerminal(prompt)
    #expect(claude.answers(for: trust) == [.trustFolder])
    let screen = DialogScreens.dialog(DialogScreens.claudeTrust)
    #expect(
      claude.keystrokes(for: .trustFolder, to: trust, screen: screen)
        == [TerminalKeys.downArrow, TerminalKeys.enter])
    // Already pointed at: Return alone.
    let pointed = DialogScreens.claudeTrust
      .replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
      .replacingOccurrences(of: "  Yes, I trust", with: "❯ Yes, I trust")
    #expect(
      claude.keystrokes(for: .trustFolder, to: trust, screen: DialogScreens.dialog(pointed))
        == [TerminalKeys.enter])
    // Another folder's, or no dialog read: nothing typed.
    let other = AgentRequestContent.inTerminal(AgentTerminalPrompt(kind: .trust, message: "/x"))
    #expect(claude.keystrokes(for: .trustFolder, to: other, screen: screen) == nil)
    #expect(claude.keystrokes(for: .trustFolder, to: trust) == nil)
    // Neither the guess of a start nor Codex's keymap answers it.
    #expect(
      claude.answers(for: .inTerminal(AgentTerminalPrompt(kind: .startup, message: nil))).isEmpty)
    #expect(codex.startupDialog(onScreen: DialogScreens.claudeTrust) == nil)
    #expect(claude.startupDialog(onScreen: DialogScreens.codexUpdate) == nil)
  }

  @Test("Claude Code's questions set aside: Chat about this's digit, read on screen, then the text")
  func claudeChatAboutThis() {
    let questions = AgentRequestContent.questions([
      AgentQuestion(
        header: "Color", text: "Pick a color?",
        options: [.init(label: "Red", description: "Rouge"), .init(label: "Blue")]),
      AgentQuestion(
        header: "Pets", text: "Pets?", options: [.init(label: "Cat"), .init(label: "Dog")],
        allowsMultipleChoices: true),
    ])
    #expect(claude.answers(for: questions).contains(.chatAboutThis))
    let screen = DialogScreens.dialog(DialogScreens.claudeChatAboutThis)
    #expect(claude.keystrokes(for: .chatAboutThis, to: questions, screen: screen) == [[0x34]])
    #expect(claude.keystrokes(for: .chatAboutThis, to: questions, screen: nil) == nil)
    // Eight options: "Chat about this" would be the tenth, with no digit.
    let many = AgentRequestContent.questions([
      AgentQuestion(
        header: nil, text: "Which?", options: (1...8).map { .init(label: "o\($0)") })
    ])
    #expect(!claude.answers(for: many).contains(.chatAboutThis))
  }

  @Test("Codex: an MCP tool's form takes the digit of Allow, Escape cancels it")
  func codexMCPTool() {
    let tool = permission(.mcp(server: "echo_box", tool: "write_note"), always: nil)
    let screen = DialogScreens.dialog(CodexApprovalScreens.codexTool)
    #expect(codex.answers(for: tool) == [.allowOnce, .deny])
    #expect(codex.keystrokes(for: .allowOnce, to: tool, screen: screen) == [[0x31]])
    #expect(codex.keystrokes(for: .deny, to: tool, screen: screen) == [[0x1B]])
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
