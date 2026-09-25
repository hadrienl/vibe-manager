import Foundation
import Testing
import VibeLocalizationTesting

@Suite("The New Session and Switch Agent sheets, in English and in French")
struct NewSessionLocalizationTests {
  @Test("The sentences of the sheets read in both languages")
  func sentences() {
    #expect(
      Localization.string("Create & Launch", module: "VibeUI", in: "fr") == "Créer et lancer")
    #expect(
      Localization.string("What are you working on?", module: "VibeUI", in: "fr")
        == "Sur quoi travaillez-vous\u{00A0}?")
    let name = "Codex"
    #expect(
      Localization.string("Switch Agent — \(name)", module: "VibeUI", in: "en")
        == "Switch Agent — Codex")
    #expect(
      Localization.string("Switch Agent — \(name)", module: "VibeUI", in: "fr")
        == "Changer d’agent — Codex")
  }

  @Test(
    "The count of problems agrees with its number",
    arguments: [
      (0, "0 problems to fix", "0 problème à corriger"),
      (1, "1 problem to fix", "1 problème à corriger"),
      (2, "2 problems to fix", "2 problèmes à corriger"),
      (1_000_000, "1,000,000 problems to fix", "1\u{202F}000\u{202F}000 problèmes à corriger"),
    ])
  func problems(count: Int, english: String, french: String) {
    #expect(Localization.string("\(count) problems to fix", module: "VibeUI", in: "en") == english)
    #expect(Localization.string("\(count) problems to fix", module: "VibeUI", in: "fr") == french)
  }
}
