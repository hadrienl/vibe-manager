import Testing
import VibeLocalizationTesting

@Suite("The composer's interruption, in English and in French")
struct InterruptLabelTests {
  @Test("Interrupting a turn reads Interrompre, never the Arrêter that stops a session (#238)")
  func interrupt() {
    #expect(
      Localization.string("Interrupt", module: "VibeConversationUI", in: "fr") == "Interrompre")
    #expect(
      Localization.string("Interrupt the agent", module: "VibeConversationUI", in: "fr")
        == "Interrompre l’agent")
    #expect(
      Localization.string("interrupted without an answer", module: "VibeConversationUI", in: "fr")
        == "interrompu sans résultat")
  }
}
