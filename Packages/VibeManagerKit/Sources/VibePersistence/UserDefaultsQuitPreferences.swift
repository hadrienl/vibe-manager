import Foundation
import VibeApplication

/// The "Don't ask again" of the question asked when quitting, kept across launches.
///
/// A key that was never written, or holds a value this build does not know, reads as the safe
/// answer: ask.
@MainActor
public final class UserDefaultsQuitPreferences: QuitPreferences {
  private let key = "application.quit.runningAgents.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var behavior: QuitBehavior {
    get { defaults.string(forKey: key).flatMap(QuitBehavior.init(rawValue:)) ?? .ask }
    set { defaults.set(newValue.rawValue, forKey: key) }
  }
}
