import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@MainActor
@Suite("What closing a session asks")
struct UserDefaultsSessionClosePreferencesTests {
  @Test("Moving a running session to To Do or Waiting asks until an answer is kept (#353)")
  func setAsideRoundTrip() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsSessionClosePreferences(suiteName: suite)
    #expect(preferences.setAsideClose == .ask)

    for answer in SetAsideClose.allCases {
      preferences.setAsideClose = answer
      #expect(UserDefaultsSessionClosePreferences(suiteName: suite).setAsideClose == answer)
    }
  }

  @Test("An answer this build does not know reads as the question")
  func unknownAnswer() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set("later", forKey: "sessions.close.onSetAside.v1")

    #expect(UserDefaultsSessionClosePreferences(suiteName: suite).setAsideClose == .ask)
  }
}
