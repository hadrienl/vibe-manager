import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeUI

@Suite("The notes' text, in English and in French")
struct NotesLocalizationTests {
  @Test("The state of the notes reads in both languages")
  func notesStates() {
    let states: [(NotesSaveState, Bool)] = [
      (.saved(at: Date()), false), (.edited, false), (.saving, true),
      (.failed(.cannotWrite(reason: "x"), retryAt: Date()), false),
      (.unreadable(reason: "x"), false),
    ]
    let titles = states.compactMap { NotesStatePresentation(state: $0.0, showsSaving: $0.1).title }
    #expect(
      titles.map { Localization.string($0, in: "en") }
        == ["Saved", "Edited", "Saving…", "Not saved", "Unreadable"])
    #expect(
      titles.map { Localization.string($0, in: "fr") }
        == ["Enregistré", "Modifié", "Enregistrement…", "Non enregistré", "Illisible"])
  }

  @Test("The toolbar's button and the floating window read in both languages (#578)")
  func toolbar() {
    #expect(
      Localization.string("Session Notes", module: "VibeUI", in: "fr") == "Notes de la session")
    #expect(
      Localization.string("Detach to a Floating Window", module: "VibeUI", in: "fr")
        == "Détacher en fenêtre flottante")
    let name = "Paiement"
    #expect(
      Localization.string("Notes · \(name)", module: "VibeUI", in: "fr") == "Notes · Paiement")
  }
}
