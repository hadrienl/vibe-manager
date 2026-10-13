import Testing

@testable import VibeApplication

@Suite("The agent's prompt read on its screen (#370)")
struct PromptInputRecognitionTests {
  /// As Claude Code 2.1.296 draws its prompt: between two rules, under the conversation.
  static func screen(_ prompt: String) -> String {
    """
    ❯ Bonjour ça va ?
    ⏺ Salut ! Ça va bien, merci.
    ✻ Worked for 1s · done 2:54 PM
    ────────────────────────────────────────
    \(prompt)
    ────────────────────────────────────────
      ➜ cwd Haiku 5.5
      ⏵⏵ auto mode on (shift+tab to cycle)
    """
  }

  @Test("An empty prompt, its pointer followed by a no-break space")
  func emptyPrompt() {
    let input = PromptInputRecognition.input(screen: Self.screen("❯\u{A0}"))
    #expect(input == [""])
    #expect(!PromptInputRecognition.holds("Bonjour ça va ?", in: input ?? []))
  }

  @Test("The prompt sent shows in the conversation above, not in the prompt")
  func conversationAboveIsNotThePrompt() {
    let input = PromptInputRecognition.input(screen: Self.screen("❯ Try \"fix lint errors\""))
    #expect(input == ["Try \"fix lint errors\""])
    #expect(!PromptInputRecognition.holds("Bonjour ça va ?", in: input ?? []))
  }

  @Test("A text typed, wrapped where the prompt is narrow")
  func wrappedText() {
    let input = PromptInputRecognition.input(
      screen: Self.screen(
        "❯ J'ai parfois ce bug. J'appuie sur\n  entrée, mais c'est interprété comme un\n  retour à la ligne."
      ))
    #expect(input?.count == 3)
    #expect(
      PromptInputRecognition.holds(
        "J'ai parfois ce bug. J'appuie sur entrée, mais c'est interprété comme un retour à la ligne.",
        in: input ?? []))
    #expect(!PromptInputRecognition.endsOnLineBreak(input ?? []))
  }

  @Test("Return taken for a line break leaves an empty line under the text")
  func lineBreak() {
    let input = PromptInputRecognition.input(screen: Self.screen("❯ Bonjour ça va ?\n"))
    #expect(input == ["Bonjour ça va ?", ""])
    #expect(PromptInputRecognition.holds("Bonjour ça va ?", in: input ?? []))
    #expect(PromptInputRecognition.endsOnLineBreak(input ?? []))
  }

  @Test("Images joined to the text show after it")
  func images() {
    let input = PromptInputRecognition.input(
      screen: Self.screen("❯ Regarde ça[Image #1] [Image #2]"))
    #expect(PromptInputRecognition.holds("Regarde ça", in: input ?? []))
  }

  @Test("A long text shown as a placeholder")
  func pastedText() {
    let input = PromptInputRecognition.input(screen: Self.screen("❯ [Pasted text #1 +40 lines]"))
    #expect(PromptInputRecognition.showsPastedText(input ?? []))
  }

  @Test("A screen without the prompt — a panel, a dialog — tells nothing")
  func noPrompt() {
    #expect(
      PromptInputRecognition.input(
        screen:
          "Auto mode setup\n❯ 1. Yes, set it up\n  2. Not now\nEnter to confirm · Esc to cancel")
        == nil)
    #expect(PromptInputRecognition.input(screen: "") == nil)
  }

  @Test("A short text is the whole prompt, never a word of a hint")
  func shortText() {
    #expect(!PromptInputRecognition.holds("fix", in: ["Try \"fix lint errors\""]))
    #expect(PromptInputRecognition.holds("fix", in: ["fix"]))
    #expect(PromptInputRecognition.holds("fix", in: ["fix[Image #1]"]))
  }

  @Test("An emoji drawn otherwise does not keep the text from being found")
  func emoji() {
    #expect(PromptInputRecognition.holds("merci 🙏🏽", in: ["merci 🙏"]))
    #expect(PromptInputRecognition.holds("merci\u{200B} !", in: ["merci !"]))
  }
}
