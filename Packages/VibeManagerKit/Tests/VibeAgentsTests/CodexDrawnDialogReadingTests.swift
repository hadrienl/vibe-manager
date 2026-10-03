import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// Approval dialogs as codex-cli 0.159.2 drew them in a pty 100 columns wide (#283), replayed by
/// `TerminalText.screen` as the application reads them before typing an answer, paths replaced.
/// The command was run outside the sandbox, Codex asking to: `-a on-request -s read-only`.
enum CodexApprovalScreens {
  static let workingDirectory =
    "/Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppps/proj"
  static let codexLongCommand = #"""
    • Running printf "%s\n" alpha-bravo-charlie-delta-echo foxtrot-golf-hotel-india-juliet kilo-lima-mi…
        + Show details


      Would you like to run the following command?

      Environment: local

      Reason: Capture the approval dialog

      $ printf "%s\n" alpha-bravo-charlie-delta-echo foxtrot-golf-hotel-india-juliet
      kilo-lima-mike-november-oscar papa-quebec-romeo-sierra-tango
      uniform-victor-whiskey-xray-yankee-zulu > /dev/null


    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `printf "%s\n" alpha-bravo-charlie-delta-
         echo foxtrot-golf-hotel-india-juliet kilo-lima-mike-november-oscar papa-quebec-romeo-sierra-
         tango uniform-victor-whiskey-xray-yankee-zulu > /dev/null` (p)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """#
  static let codexHeredoc = #"""
    • Running cat <<'EOF' > /dev/null …
        + Show details


      Would you like to run the following command?

      Environment: local

      Reason: Capture a multi-line command

      $ cat <<'EOF' > /dev/null
      first line of the heredoc
      second line of the heredoc
      EOF


    › 1. Yes, proceed (y)
      2. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """#
  static let codexPatchOne = #"""
    • Edited notes.txt (+1 -0)
        2 +world
        + Show details



      Would you like to make the following edits?

      Description: Apply proposed file edits
      Destination:
      /Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppp
      s/proj/notes.txt


    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for these files (a)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """#
  static let codexPatchSeveral = #"""
      Would you like to make the following edits?

      Description: Apply proposed file edits
      Destination:
      /Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppp
      s/proj/App/Model.swift
      Destination:
      /Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppp
      s/proj/App/Models/Model.swift
      Destination:
      /Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppp
      s/proj/docs/guide.md
      Destination:
      /Users/a/Documents/clients/acme-corporation/payments/a-rather-long-repository-name-that-wrappppp
      s/proj/notes.txt


    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for these files (a)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """#
  static let codexTool = #"""
    • Calling echo-box.write_note
        + Show details






      Field 1/1
      Allow the echo-box MCP server to run tool "write_note"?

      text: hello

      › 1. Allow                   Run the tool and continue
        2. Allow for this session  Run the tool and remember this choice for this session
        3. Always allow            Run the tool and remember this choice for future tool calls
        4. Cancel                  Cancel this tool call
      enter to submit | esc to cancel
    """#
  static let codexCutShort = #"""
      Would you like to run the following command?

      Environment: local

      Reason: Capture the approval dialog

      [… 9 lines] ctrl+a view all
    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `printf "%s\n" alpha-bravo-charlie-delta-
         echo foxtrot-golf-hotel-india-juliet kilo-lima-mike-november-oscar papa-quebec-romeo-sierra-
      Press enter to confirm or esc to cancel
    """#
  /// From `approval_overlay.rs` in 0.159.2, no network access being drawn in the captures: Codex
  /// asks for one only behind its managed network proxy.
  static let codexNetwork = """
      Do you want to approve network access to "example.org"?

    › 1. Yes, just this once (y)
      2. Yes, and allow this host for this conversation (a)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """
}

@Suite("Codex's approval dialog, read off the screen (#283)")
struct CodexDrawnDialogReadingTests {
  private func dialog(_ screen: String) -> AgentDrawnDialog? {
    CodexDrawnDialogReading.dialog(onScreen: screen)
  }

  private func request(
    _ tool: AgentToolPermission.Tool, _ subject: String?, purpose: String? = nil
  ) -> AgentRequest {
    AgentRequest(
      id: AgentRequestID(sessionID: SessionID(), key: "r"), receivedAt: Date(), kind: .approval,
      content: .permission(
        AgentToolPermission(
          tool: tool, toolName: "t", subject: subject, purpose: purpose,
          workingDirectory: CodexApprovalScreens.workingDirectory)),
      reference: AgentToolReference(tool: "t"), isShown: false)
  }

  @Test("A long command, wrapped over three lines, is read whole")
  func longCommand() throws {
    let command =
      #"printf "%s\n" alpha-bravo-charlie-delta-echo foxtrot-golf-hotel-india-juliet kilo-lima-mike-november-oscar papa-quebec-romeo-sierra-tango uniform-victor-whiskey-xray-yankee-zulu > /dev/null"#
    let shown = try #require(dialog(CodexApprovalScreens.codexLongCommand))
    #expect(shown.quotesWhole)
    #expect(shown.matches(request(.shell, command)))
    // The start the history cell above it shows, cut short, is not it.
    #expect(!shown.matches(request(.shell, #"printf "%s\n" alpha-bravo-charlie-delta-echo"#)))
    #expect(!shown.matches(request(.shell, command + " 2>&1")))
  }

  @Test("A command on several lines is read with all of them")
  func heredoc() throws {
    let command = """
      cat <<'EOF' > /dev/null
      first line of the heredoc
      second line of the heredoc
      EOF
      """
    let shown = try #require(dialog(CodexApprovalScreens.codexHeredoc))
    #expect(shown.matches(request(.shell, command)))
    #expect(!shown.matches(request(.shell, "cat <<'EOF' > /dev/null")))
  }

  @Test("A short command, under the history cell that runs it")
  func shortCommand() throws {
    let shown = try #require(dialog(DialogScreens.codexCommand))
    #expect(shown.matches(request(.shell, "touch made-by-codex.txt")))
  }

  @Test("A patch is every path it writes to, a move's destination included")
  func patches() throws {
    let one = try #require(dialog(CodexApprovalScreens.codexPatchOne))
    #expect(one.matches(request(.patch, "notes.txt")))
    #expect(!one.matches(request(.patch, "notes.txt\ndocs/guide.md")))
    let several = try #require(dialog(CodexApprovalScreens.codexPatchSeveral))
    let files = "notes.txt\ndocs/guide.md\nApp/Model.swift\nApp/Models/Model.swift"
    #expect(several.matches(request(.patch, files)))
    #expect(!several.matches(request(.patch, "notes.txt\ndocs/guide.md\nApp/Model.swift")))
  }

  @Test("A network access is its host")
  func network() throws {
    let shown = try #require(dialog(CodexApprovalScreens.codexNetwork))
    #expect(shown.matches(request(.shell, "curl x", purpose: "network-access https://example.org")))
    #expect(!shown.matches(request(.shell, "curl x", purpose: "network-access example.com")))
  }

  /// An MCP tool's form shows its arguments shortened and cut: two calls of the same tool read
  /// the same, and are answered in the session.
  @Test(
    "Nothing is read of an MCP tool's form, a dialog cut short, gone, or not Codex's",
    arguments: [
      CodexApprovalScreens.codexTool,
      CodexApprovalScreens.codexCutShort,
    "› Ask Codex to do anything\n\n  ? for shortcuts",
    DialogScreens.claudeBash,
  ])
  func unreadable(_ screen: String) {
    #expect(dialog(screen) == nil)
  }

  @Test("Codex's keymap waits for the screen, and leaves a report it cannot read to the session")
  func keymap() {
    let keymap = CodexAnswerKeymap()
    #expect(keymap.readsRequestOnScreen)
    #expect(keymap.answers(for: .unreadable(tool: "Bash")).isEmpty)
    #expect(keymap.drawnDialog(onScreen: DialogScreens.codexCommand) != nil)
    #expect(!ClaudeCodeAnswerKeymap().readsRequestOnScreen)
  }
}
