import Foundation
import Testing
import VibeDomain
import VibeLocalizationTesting

@Suite("The domain's text, in English and in French")
struct LocalizationTests {
  @Test("Where a pattern is used reads in both languages")
  func extractionPlaces() {
    let place = PromptTemplateExtractionUse.Place.sessionName
    #expect(Localization.string(place.label, in: "en") == "Session name")
    #expect(Localization.string(place.label, in: "fr") == "Nom de la session")
    #expect(
      Localization.string(PromptTemplateExtractionUse.Place.prompt.label, in: "fr") == "Prompt")
  }

  @Test("A validation problem reads in both languages, with its argument in place")
  func issues() {
    #expect(SessionDraftIssue.nameMissing.message == "A name is required.")
    #expect(
      Localization.string("A name is required.", module: "VibeDomain", in: "fr")
        == "Un nom est obligatoire.")
    let id = "codex"
    #expect(
      Localization.string(
        "The agent \(id) is not registered any more.", module: "VibeDomain", in: "fr")
        == "L’agent codex n’est plus enregistré.")
    // French typography: a no-break space before a semicolon.
    let size = "1 KB"
    #expect(
      Localization.string(
        "The prompt weighs \(size); agents accept \(size).", module: "VibeDomain", in: "fr")
        == "Le prompt pèse 1 KB\u{00A0}; les agents acceptent 1 KB.")
  }

  @Test("The examples are written in English by default")
  func examples() {
    let review = PromptTemplateExamples.review(createdAt: Date())
    #expect(review.name == "Review")
    #expect(review.sessionNamePattern.hasPrefix("Review {{url|"))
    #expect(
      Localization.string("Review", module: "VibeDomain", in: "fr") == "Revue")
  }
}
