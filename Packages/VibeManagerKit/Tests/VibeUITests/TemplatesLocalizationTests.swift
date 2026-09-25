import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

@MainActor
@Suite("The prompt templates' text, in English and in French")
struct TemplatesLocalizationTests {
  @Test("A new template is untitled in the language of the application")
  func untitled() async {
    let model = PromptTemplateLibraryModel(repository: InMemoryPromptTemplateRepository())
    await model.load()
    model.newTemplate()
    // The test runner declares no localization of its own, so its strings are English.
    #expect(model.editing?.name == "Untitled Template")
    #expect(
      Localization.string("Untitled Template", module: "VibeUI", in: "fr") == "Modèle sans titre")
  }

  @Test(
    "The count of imported templates agrees with its number",
    arguments: [
      (0, "0 templates imported.", "0 modèle importé."),
      (1, "1 template imported.", "1 modèle importé."),
      (2, "2 templates imported.", "2 modèles importés."),
      (1_000_000, "1,000,000 templates imported.", "1\u{202F}000\u{202F}000 modèles importés."),
    ])
  func importedCount(count: Int, english: String, french: String) {
    #expect(
      Localization.string("\(count) templates imported.", module: "VibeUI", in: "en") == english)
    #expect(
      Localization.string("\(count) templates imported.", module: "VibeUI", in: "fr") == french)
  }

  @Test("The editor's sentences read in French, with French typography")
  func sentences() {
    let name = "Review"
    #expect(
      Localization.string("Delete “\(name)”?", module: "VibeUI", in: "fr")
        == "Supprimer «\u{00A0}Review\u{00A0}»\u{00A0}?")
    let reason = "bad"
    #expect(
      Localization.string("Invalid pattern: \(reason)", module: "VibeUI", in: "en")
        == "Invalid pattern: bad")
    #expect(
      Localization.string("Invalid pattern: \(reason)", module: "VibeUI", in: "fr")
        == "Motif non valide\u{00A0}: bad")
  }
}
