import Testing

@testable import VibeApplication

@Suite("A panel of the agent's terminal, read from its screen (#219)")
struct AgentPanelRecognitionTests {
  @Test("The panels of Claude Code and Codex end on the keys that close them")
  func panels() {
    #expect(
      AgentPanelRecognition.showsPanel(
        screen: """
          Manage MCP servers
          ❯ ⚠ figma          needs authentication
          ↑/↓ to navigate · Enter to confirm · Esc to cancel

          """))
    #expect(
      AgentPanelRecognition.showsPanel(
        screen: "Select Model\n› 1. GPT-5.6-Sol\n  2. GPT-5.5\nenter select · esc back"))
    #expect(AgentPanelRecognition.showsPanel(screen: "Press Esc to go back"))
  }

  @Test("A prompt at rest, a turn under way, or a hint gone up the screen is no panel")
  func noPanel() {
    #expect(!AgentPanelRecognition.showsPanel(screen: "❯ \n? for shortcuts"))
    #expect(!AgentPanelRecognition.showsPanel(screen: "✻ Thinking… (esc to interrupt)"))
    #expect(!AgentPanelRecognition.showsPanel(screen: "› Ask Codex to do anything\n← for agents"))
    let scrolled = "Esc to cancel\n" + (1...8).map { "line \($0)" }.joined(separator: "\n")
    #expect(!AgentPanelRecognition.showsPanel(screen: scrolled))
    #expect(!AgentPanelRecognition.showsPanel(screen: ""))
    // The agent's own words, above the prompt at rest (#319).
    #expect(
      !AgentPanelRecognition.showsPanel(
        screen: "Then press Esc to exit the editor.\n────\n❯ \n────\n  ⏵⏵ auto mode on"))
    #expect(
      !AgentPanelRecognition.showsPanel(
        screen: "Esc to cancel, as the menu says.\n› Ask Codex to do anything\n← for agents"))
  }

  @Test("Prompts queued: Claude Code offers to send them now, whatever keys it is bound to (#341)")
  func sendNowHint() {
    let queued = """
      ✻ Running… (esc to interrupt)
        ⎿  Two messages
      ────
      ❯ 
      ────
        Press up to edit queued messages · ctrl+x ctrl+s to send now
      """
    #expect(AgentPanelRecognition.showsSendNowHint(screen: queued))
    #expect(
      AgentPanelRecognition.showsSendNowHint(
        screen: queued.replacing("ctrl+x ctrl+s", with: "ctrl+g")))
    #expect(!AgentPanelRecognition.showsSendNowHint(screen: "────\n❯ \n────\n  ? for shortcuts"))
    #expect(!AgentPanelRecognition.showsSendNowHint(screen: "✻ Thinking… (esc to interrupt)"))
    #expect(
      !AgentPanelRecognition.showsSendNowHint(
        screen: "Manage MCP servers\n❯ figma\nEnter to confirm · Esc to cancel"))
    #expect(!AgentPanelRecognition.showsSendNowHint(screen: ""))
    // The same words above the prompt — the agent's, or a message queued — are no offer.
    #expect(
      !AgentPanelRecognition.showsSendNowHint(
        screen: """
          Claude Code shows ctrl+x ctrl+s to send now.
          ✻ Running… (esc to interrupt)
          ────
          ❯ 
          ────
            ? for shortcuts
          """))
    #expect(!AgentPanelRecognition.showsSendNowHint(screen: "Press ctrl+x ctrl+s to send now"))
  }
}
