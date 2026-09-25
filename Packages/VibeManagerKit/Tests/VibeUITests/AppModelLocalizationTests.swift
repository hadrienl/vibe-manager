import Foundation
import Testing
import VibeLocalizationTesting

@testable import VibeUI

@Suite("The workspace's sentences, in English and in French")
struct AppModelLocalizationTests {
  @Test(
    "A restoration report agrees with its counts",
    arguments: [
      (0, "0 sessions came back.", "0 session a été rétablie."),
      (1, "1 session came back.", "1 session a été rétablie."),
      (2, "2 sessions came back.", "2 sessions ont été rétablies."),
      (
        1_000_000, "1,000,000 sessions came back.",
        "1\u{202F}000\u{202F}000 sessions ont été rétablies."
      ),
    ])
  func restored(count: Int, english: String, french: String) {
    #expect(
      Localization.string("\(count) sessions came back.", module: "VibeUI", in: "en") == english)
    #expect(
      Localization.string("\(count) sessions came back.", module: "VibeUI", in: "fr") == french)
  }

  @Test("A report reads in English by default, singulars included")
  func report() {
    let report = AppModel.RestoreReport(restartedCount: 1, cancelledCount: 1, lines: [])
    #expect(report.message == "1 more was left closed when you cancelled. 1 session came back.")
    let offer = AppModel.RestoreOffer(
      sessionCount: 1, leftoverProcessIdentifiers: [], interruptedAt: nil)
    #expect(offer.message == "Vibe Manager stopped unexpectedly. 1 session was running.")
    #expect(
      AppModel.DetachedNotice(runningCount: 2, endedCount: 1).message
        == "3 agents kept running while Vibe Manager was closed; 1 has finished since.")
  }

  @Test("The detached notice agrees in French too")
  func detached() {
    #expect(
      Localization.string(
        "\(1) agents kept running while Vibe Manager was closed.", module: "VibeUI", in: "fr")
        == "1 agent a continué de tourner pendant que Vibe Manager était fermé.")
    let (total, ended) = (4, 2)
    #expect(
      Localization.string(
        "\(total) agents kept running while Vibe Manager was closed; \(ended) have finished since.",
        module: "VibeUI", in: "fr")
        == "4 agents ont continué de tourner pendant que Vibe Manager était fermé\u{00A0}; 2 se sont terminés depuis."
    )
  }

  @Test("The line above a restarted agent reads in both languages")
  @MainActor
  func separator() {
    let line = SessionLauncher.separator(for: .freshWithoutContext, at: Date())
    #expect(line.contains("── Restart · "))
    #expect(line.contains(" · new process ──"))
    #expect(
      Localization.string("new process, given a summary", module: "VibeUI", in: "fr")
        == "nouveau processus, avec un résumé")
  }
}
