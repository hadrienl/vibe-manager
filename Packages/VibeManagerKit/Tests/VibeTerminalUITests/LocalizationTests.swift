import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeTerminalUI

@Suite("The terminal's text, in English and in French")
struct LocalizationTests {
  @Test("A terminal's state reads in the language of the application")
  func states() {
    // The test runner declares no localization of its own, so its strings are English.
    #expect(TerminalPaneModel.Status.exited(code: 0).label == "Finished")
    #expect(TerminalPaneModel.Status.exited(code: 2).label == "Exited with code 2")
    #expect(
      Localization.string("Finished", module: "VibeTerminalUI", in: "fr") == "Terminé")
    let code = "2"
    #expect(
      Localization.string("Exited with code \(code)", module: "VibeTerminalUI", in: "fr")
        == "Terminé avec le code 2")
  }

  @Test("VoiceOver names the terminal in the language of the application")
  @MainActor
  func accessibility() {
    #expect(AccessibleTerminalView().accessibilityLabel() == "Terminal")
    #expect(
      Localization.string(
        "Read Last Output, Control-Option-Command-O, reads the last lines the agent wrote.",
        module: "VibeTerminalUI", in: "fr")
        == "Lire la dernière sortie, Contrôle-Option-Commande-O, lit les dernières lignes écrites par l’agent."
    )
  }
}
