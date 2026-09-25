import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeUI

@Suite("The inspector's text, in English and in French")
struct InspectorLocalizationTests {
  @Test("The Git lists are named in both languages")
  func columns() {
    #expect(
      ChangeColumn.allCases.map { Localization.string($0.title, in: "en") }
        == ["Conflicts", "Staged", "Unstaged", "Untracked", "Committed"])
    #expect(
      ChangeColumn.allCases.map { Localization.string($0.title, in: "fr") }
        == ["Conflits", "Indexés", "Non indexés", "Non suivis", "Commités"])
  }

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

  @Test(
    "A count of files agrees with its number",
    arguments: [
      (0, "0 staged", "0 indexé"), (1, "1 staged", "1 indexé"), (2, "2 staged", "2 indexés"),
      (1_000_000, "1,000,000 staged", "1\u{202F}000\u{202F}000 indexés"),
    ])
  func staged(count: Int, english: String, french: String) {
    #expect(Localization.string("\(count) staged", module: "VibeUI", in: "en") == english)
    #expect(Localization.string("\(count) staged", module: "VibeUI", in: "fr") == french)
  }

  @Test(
    "Committed files and clean repositories agree with their number",
    arguments: [
      (0, "0 files committed since main", "0 fichier commité depuis main"),
      (1, "1 file committed since main", "1 fichier commité depuis main"),
      (2, "2 files committed since main", "2 fichiers commités depuis main"),
      (
        1_000_000, "1,000,000 files committed since main",
        "1\u{202F}000\u{202F}000 fichiers commités depuis main"
      ),
    ])
  func committed(count: Int, english: String, french: String) {
    let base = "main"
    let value: String.LocalizationValue = "\(count) files committed since \(base)"
    #expect(Localization.string(value, module: "VibeUI", in: "en") == english)
    #expect(Localization.string(value, module: "VibeUI", in: "fr") == french)
  }

  @Test("A clean pane counts its repositories in both languages")
  func allClean() {
    let one = 1
    let two = 2
    #expect(
      Localization.string("Nothing to commit in \(one) repositories", module: "VibeUI", in: "en")
        == "Nothing to commit in 1 repository")
    #expect(
      Localization.string("Nothing to commit in \(two) repositories", module: "VibeUI", in: "fr")
        == "Rien à commiter dans 2 dépôts")
  }

  @Test("French punctuation takes a no-break space")
  func typography() {
    let change = "modifié"
    #expect(
      Localization.string("staged: \(change)", module: "VibeUI", in: "fr")
        == "indexé\u{00A0}: modifié")
    #expect(
      Localization.string("renamed, \(92) % similar", module: "VibeUI", in: "fr")
        == "renommé, similaire à 92\u{00A0}%")
  }
}
