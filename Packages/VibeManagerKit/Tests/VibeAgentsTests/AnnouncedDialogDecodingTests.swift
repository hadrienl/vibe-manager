import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

private func notification(_ type: String, _ message: String) -> AgentActivityEvent {
  AgentActivityEvent(
    name: "Notification", date: Date(),
    payload: Data(
      #"{"hook_event_name":"Notification","message":"\#(message)","notification_type":"\#(type)"}"#
        .utf8))
}

@Suite("Dialogs announced by the CLIs, read (#273)")
struct AnnouncedDialogDecodingTests {
  @Test("Claude Code: a sandboxed command's network access, which has no PermissionRequest")
  func claudeNetwork() {
    // As Claude Code 2.1.285 reported it, sandbox on, `curl` to a host not allowed.
    let signal = ClaudeCodeSignalDecoder().signal(
      for: notification("permission_prompt", "A sandboxed command needs network access"))
    #expect(
      signal
        == .dialogAnnounced(
          AgentTerminalPrompt(kind: .network, message: "A sandboxed command needs network access")))
  }

  @Test("Claude Code: the other dialogs its notifications announce")
  func claudeOthers() {
    let decoder = ClaudeCodeSignalDecoder()
    let kinds: [String: AgentTerminalPrompt.Kind] = [
      "elicitation_url_dialog": .form, "agent_needs_input": .other,
      "quota_auto_resume_stale": .other,
    ]
    for (type, kind) in kinds {
      #expect(
        decoder.signal(for: notification(type, "Claude needs your permission"))
          == .dialogAnnounced(
            AgentTerminalPrompt(kind: kind, message: "Claude needs your permission")))
    }
    #expect(
      decoder.signal(for: notification("idle_prompt", "Claude is waiting for your input"))
        == .waitingForInput)
    // Any other permission repeats its `PermissionRequest`, and may come once it is answered.
    #expect(decoder.signal(for: notification("permission_prompt", "Claude needs your permission")) == nil)
    // Its `Elicitation` hook reports the same dialog, and says when it ends.
    #expect(decoder.signal(for: notification("elicitation_dialog", "Form")) == nil)
    // A teammate's permission, reported by its own hooks, may come once answered.
    #expect(decoder.signal(for: notification("worker_permission_prompt", "Worker needs it")) == nil)
    #expect(decoder.signal(for: notification("auth_success", "Signed in")) == nil)
  }

  @Test("Codex: a permission is reported before its review, and drawn once it says so")
  func codexPermission() throws {
    let decoder = CodexSignalDecoder()
    let event = AgentActivityEvent(
      name: "PermissionRequest", date: Date(),
      payload: Data(
        #"{"tool_name":"Bash","tool_input":{"command":"touch a","description":"Create a"}}"#.utf8))
    guard case .questionAsked(.approval, _, let notice?) = decoder.signal(for: event) else {
      Issue.record("not a request")
      return
    }
    #expect(!notice.isShown)
    // What codex-cli 0.159.2 wrote to its terminal as it drew the dialog.
    #expect(
      decoder.signal(forTerminalNotification: "Approval requested: /bin/zsh -lc 'touch made-by...")
        == .dialogDrawn(AgentDrawnDialog(.commandStart("touch made-by"))))
    #expect(
      decoder.signal(forTerminalNotification: "Codex wants to edit a.swift")
        == .dialogDrawn(AgentDrawnDialog(.file("a.swift"))))
    #expect(
      decoder.signal(forTerminalNotification: "Codex wants to edit 3 files")
        == .dialogDrawn(AgentDrawnDialog(.files)))
    // A command short enough to be quoted whole, its closing quote taken off.
    #expect(CodexSignalDecoder.commandStart(quoted: "/bin/zsh -lc 'pwd'") == "pwd")
    #expect(CodexSignalDecoder.commandStart(quoted: "git status") == "git status")
  }

  @Test("Codex: the dialogs no hook reports")
  func codexAnnounced() {
    let decoder = CodexSignalDecoder()
    func announced(_ kind: AgentTerminalPrompt.Kind, _ message: String) -> AgentSignal {
      .dialogAnnounced(AgentTerminalPrompt(kind: kind, message: message))
    }
    let expected: [String: AgentSignal?] = [
      "Approval requested by github": .dialogDrawn(
        AgentDrawnDialog(.server("github")),
        otherwise: AgentTerminalPrompt(kind: .form, message: "Approval requested by github")),
      "Plan mode prompt: Implement this plan?": announced(
        .plan, "Plan mode prompt: Implement this plan?"),
      "Plan mode prompt: Which database?": announced(.question, "Plan mode prompt: Which database?"),
      "Question: Tea or coffee?": announced(.question, "Question: Tea or coffee?"),
      "Plan mode prompt: Apply reasoning change": nil,
      "Agent turn complete": nil,
    ]
    for (message, signal) in expected {
      #expect(decoder.signal(forTerminalNotification: message) == signal)
    }
    #expect(ClaudeCodeSignalDecoder().signal(forTerminalNotification: "Question: x") == nil)
  }

  @Test("Codex is launched to write those notifications, and nothing else of the user's changes")
  func codexOptions() {
    let plan = AgentLaunchPlan(
      providerID: CodexAgentProvider.id, executablePath: "/bin/codex", arguments: ["codex"],
      environment: [:], workingDirectoryPath: "/tmp", promptDelivery: .none, version: nil)
    let arguments = CodexAgentProvider.make(environment: [:]).reportingActivity(
      plan, to: URL(fileURLWithPath: "/l"))
      .arguments
    #expect(arguments.contains(#"tui.notification_method="osc9""#))
    #expect(arguments.contains(#"tui.notification_condition="always""#))
    // The hooks, and so what Codex asked the user to approve, are the same as before.
    #expect(CodexActivityHooks.hookOptions(in: arguments) == CodexActivityHooks.options())
  }
}
