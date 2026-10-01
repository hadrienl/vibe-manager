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
  }
}
