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
    #expect(TerminalPaneModel.Status.exited(code: 2).label == "Process failed (code 2)")
    #expect(
      TerminalPaneModel.Status.terminated(signal: 9).label == "Process interrupted (signal 9)")
    #expect(
      Localization.string("Finished", module: "VibeTerminalUI", in: "fr") == "Processus terminé")
    // The process's words, not a column's (#246): the session's own column may be In Progress.
    #expect(
      Localization.string("Running", module: "VibeTerminalUI", in: "fr") == "Processus en cours")
    let code = "2"
    #expect(
      Localization.string("Process failed (code \(code))", module: "VibeTerminalUI", in: "fr")
        == "Processus en erreur (code 2)")
    let signal = "9"
    #expect(
      Localization.string(
        "Process interrupted (signal \(signal))", module: "VibeTerminalUI", in: "fr")
        == "Processus interrompu (signal 9)")
  }

  @Test("A session's status bar says Close Session, a confirmation to come (#238)")
  func closeSession() {
    #expect(
      Localization.string("Close Session…", module: "VibeTerminalUI", in: "fr")
        == "Fermer la session…")
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
