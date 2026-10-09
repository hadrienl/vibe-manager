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

@MainActor
@Suite("The voice that reads the answers (#357)")
struct UserDefaultsSpeechSettingsStoreTests {
  @Test("A choice survives a relaunch; one this build cannot read is the default")
  func roundTrip() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSpeechSettingsStore(suiteName: suite)
    #expect(store.settings == SpeechSettings())

    store.settings = SpeechSettings(voice: .aiden, language: .german)
    #expect(
      UserDefaultsSpeechSettingsStore(suiteName: suite).settings
        == SpeechSettings(voice: .aiden, language: .german))

    UserDefaults(suiteName: suite)?.set(Data("{}".utf8), forKey: "speech.settings.v1")
    #expect(UserDefaultsSpeechSettingsStore(suiteName: suite).settings == SpeechSettings())
  }
}
