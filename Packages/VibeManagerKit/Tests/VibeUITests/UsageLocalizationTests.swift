import Foundation
import Testing
import VibeDomain
import VibeLocalizationTesting

@testable import VibeUI

@Suite("The usage figures, in English and in French")
struct UsageLocalizationTests {
  @Test("The periods and the groupings read in both languages")
  func periodsAndGroupings() {
    #expect(
      UsagePeriod.allCases.map { Localization.string(UsagePresentation.periodName($0), in: "en") }
        == ["Today", "Last 7 days", "Last 30 days", "This month", "Previous month", "All time"])
    #expect(
      UsagePeriod.allCases.map { Localization.string(UsagePresentation.periodName($0), in: "fr") }
        == [
          "Aujourd’hui", "7 derniers jours", "30 derniers jours", "Ce mois-ci", "Mois précédent",
          "Depuis toujours",
        ])
    #expect(
      UsageGrouping.allCases.map {
        Localization.string(UsagePresentation.groupingName($0), in: "fr")
      } == ["Session", "Agent", "Modèle"])
  }

  @Test(
    "A count of runs agrees with its number",
    arguments: [
      (0, "0 starts", "0 lancement"), (1, "1 start", "1 lancement"),
      (2, "2 starts", "2 lancements"),
      (1_000_000, "1,000,000 starts", "1\u{202F}000\u{202F}000 lancements"),
    ])
  func starts(count: Int, english: String, french: String) {
    #expect(Localization.string("\(count) starts", module: "VibeUI", in: "en") == english)
    #expect(Localization.string("\(count) starts", module: "VibeUI", in: "fr") == french)
  }

  @Test(
    "A count of files agrees with its number",
    arguments: [
      (0, "0 files", "0 fichier"), (1, "1 file", "1 fichier"), (2, "2 files", "2 fichiers"),
      (1_000_000, "1,000,000 files", "1\u{202F}000\u{202F}000 fichiers"),
    ])
  func files(count: Int, english: String, french: String) {
    #expect(Localization.string("\(count) files", module: "VibeUI", in: "en") == english)
    #expect(Localization.string("\(count) files", module: "VibeUI", in: "fr") == french)
  }

  @Test("One of each run is said in the singular")
  func singulars() {
    var counts = UsageRunCounts()
    counts.starts = 1
    counts.resumes = 1
    counts.restarts = 1
    counts.afterRelaunch = 1
    counts.afterSwitch = 1
    #expect(
      UsagePresentation.runs(counts)
        == "1 start · 1 resume · 1 new process (1 after relaunch) · 1 switch")
  }

  @Test("The token summary reads in French")
  func tokenSummary() {
    let value = "12.3 k"
    #expect(Localization.string("\(value) in", module: "VibeUI", in: "fr") == "12.3 k en entrée")
    #expect(
      Localization.string("\(value) cache read", module: "VibeUI", in: "fr")
        == "12.3 k lus en cache")
  }
}
