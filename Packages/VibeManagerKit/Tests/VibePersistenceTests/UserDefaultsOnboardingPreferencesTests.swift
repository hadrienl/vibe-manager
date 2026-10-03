import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@MainActor
@Suite("The tour's progress, across launches")
struct UserDefaultsOnboardingPreferencesTests {
  @Test("Not started until written; what is written survives a relaunch")
  func roundTrip() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsOnboardingPreferences(suiteName: suite)
    #expect(preferences.tour == .notStarted)
    #expect(!preferences.isTourSuppressed)

    let session = SessionID()
    preferences.tour = .step(.statuses, session: session)
    #expect(
      UserDefaultsOnboardingPreferences(suiteName: suite).tour
        == .step(.statuses, session: session))

    preferences.tour = .finished
    #expect(UserDefaultsOnboardingPreferences(suiteName: suite).tour == .finished)
  }

  @Test("A value this build cannot read is a tour not started, not a failure")
  func unreadableValue() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(Data("{\"later\":{}}".utf8), forKey: "onboarding.tour.v1")

    #expect(UserDefaultsOnboardingPreferences(suiteName: suite).tour == .notStarted)
  }

  @Test("Suppressed by its key, as the smoke test sets it")
  func suppressed() {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    UserDefaults(suiteName: suite)?.set(true, forKey: "onboarding.tourSuppressed")

    #expect(UserDefaultsOnboardingPreferences(suiteName: suite).isTourSuppressed)
  }
}
