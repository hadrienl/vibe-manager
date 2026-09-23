import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@MainActor
@Suite("The editor preference")
struct UserDefaultsFileOpeningPreferencesTests {
  @Test("No choice until one is made; a choice survives a relaunch and can be withdrawn")
  func roundTrip() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsFileOpeningPreferences(suiteName: suite)
    #expect(preferences.editor == nil)

    preferences.editor = .application(bundleIdentifier: "dev.zed.Zed")
    #expect(
      UserDefaultsFileOpeningPreferences(suiteName: suite).editor
        == .application(bundleIdentifier: "dev.zed.Zed"))

    preferences.editor = .defaultApplication
    #expect(UserDefaultsFileOpeningPreferences(suiteName: suite).editor == .defaultApplication)

    preferences.editor = nil
    #expect(UserDefaultsFileOpeningPreferences(suiteName: suite).editor == nil)
  }

  @Test("A value this build cannot read is no choice, not a failure")
  func unreadableValue() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(
      Data("{\"unknown\":{}}".utf8), forKey: "inspector.fileOpening.editor.v1")

    #expect(UserDefaultsFileOpeningPreferences(suiteName: suite).editor == nil)
  }
}
