import Foundation
import Testing
import VibeApplication
import VibeLocalizationTesting

@Suite("The application's text, in English and in French")
struct LocalizationTests {
  @Test("The tabs and the sort orders of the sidebar read in both languages")
  func scopesAndSorts() {
    #expect(
      SessionScope.allCases.map { Localization.string($0.label, in: "en") } == ["Active", "Closed"])
    #expect(
      SessionScope.allCases.map { Localization.string($0.label, in: "fr") } == [
        "Actives", "Fermées",
      ])
    #expect(
      SessionSort.allCases.map { Localization.string($0.label, in: "en") }
        == ["Last Activity", "Date Created", "Name"])
    #expect(
      SessionSort.allCases.map { Localization.string($0.label, in: "fr") }
        == ["Dernière activité", "Date de création", "Nom"])
  }

  @Test(
    "A size in bytes agrees with its number",
    arguments: [
      (0, "0 bytes", "0 octet"), (1, "1 byte", "1 octet"), (2, "2 bytes", "2 octets"),
      (1_000_000, "1,000,000 bytes", "1\u{202F}000\u{202F}000 octets"),
    ])
  func bytes(count: Int, english: String, french: String) {
    #expect(Localization.string("\(count) bytes", module: "VibeApplication", in: "en") == english)
    #expect(Localization.string("\(count) bytes", module: "VibeApplication", in: "fr") == french)
  }

  @Test("An error reads in both languages")
  func errors() {
    #expect(
      TerminalError.hostStopped.errorDescription
        == "The terminal host stopped, and this agent was stopped with it.")
    #expect(
      Localization.string(
        "The terminal host stopped, and this agent was stopped with it.", module: "VibeApplication",
        in: "fr") == "L’hôte des terminaux s’est arrêté, et cet agent avec lui.")
    #expect(
      RepositoryStatusIssue.locked(lockPath: "/r/.git/index.lock", since: Date()).message
        == "Another Git process has been working in this repository for 1 min.")
  }
}
