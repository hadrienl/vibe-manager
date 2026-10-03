import Foundation
import VibeApplication
import VibeDomain

/// The first launch's tour (#338), kept with the other interface preferences.
///
/// A key that was never written reads as a tour not started; one this build cannot read, as well:
/// the launch then decides from the sessions, and a user who has some is never shown the tour.
@MainActor
public final class UserDefaultsOnboardingPreferences: OnboardingPreferences {
  private let key = "onboarding.tour.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var tour: OnboardingTour {
    get {
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode(OnboardingTour.self, from: $0)
      }
        ?? .notStarted
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
  }

  /// Never written by the application: `-onboarding.tourSuppressed YES` on the command line, as
  /// the interface smoke test passes it.
  public var isTourSuppressed: Bool {
    defaults.bool(forKey: "onboarding.tourSuppressed")
  }
}
