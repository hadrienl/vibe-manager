import Testing
import VibeDomain
import VibeLocalizationTesting

@testable import VibeConversationUI

@Suite("A conversation whose agent stopped on an error")
@MainActor
struct StoppedOnErrorTests {
  @Test("An agent that ended on an error is told apart from a session closed on purpose (#235)")
  func toldApart() {
    let model = ConversationModel(sessionID: SessionID())
    var running = true
    var onError = false
    model.processRunning = { running }
    model.endedOnError = { onError }
    #expect(!model.hasStoppedOnError)

    // Closed by the user: stopped, not on an error.
    running = false
    #expect(!model.hasStoppedOnError)

    // Ended on its own.
    onError = true
    #expect(model.hasStoppedOnError)

    // Restarted: no longer said.
    running = true
    #expect(!model.hasStoppedOnError)
  }

  @Test("The message says so in French too")
  func french() {
    #expect(
      Localization.string(
        "The agent stopped on an error. Its terminal says why.", module: "VibeConversationUI",
        in: "fr") == "L’agent s’est arrêté sur une erreur. Son terminal dit pourquoi.")
  }
}
