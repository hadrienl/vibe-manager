import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@MainActor
@Suite("The dictation settings (#340)")
struct UserDefaultsDictationSettingsStoreTests {
  @Test("The large model and the language heard until chosen; a choice survives a relaunch")
  func roundTrip() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsDictationSettingsStore(suiteName: suite)
    #expect(store.settings == DictationSettings(variant: .largeTurbo, language: nil))

    store.settings = DictationSettings(variant: .small, language: "fr")
    #expect(
      UserDefaultsDictationSettingsStore(suiteName: suite).settings
        == DictationSettings(variant: .small, language: "fr"))
  }

  @Test("A value this build cannot read is the default, not a failure")
  func unreadableValue() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(
      Data("{\"variant\":\"enormous\"}".utf8), forKey: "dictation.settings.v1")

    #expect(UserDefaultsDictationSettingsStore(suiteName: suite).settings == DictationSettings())
  }
}
