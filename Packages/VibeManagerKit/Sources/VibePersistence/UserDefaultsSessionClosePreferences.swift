import Foundation
import VibeApplication

/// The "Don't ask again" of the close confirmation, kept across launches.
///
/// Stored as its negation, so a key that was never written reads as the safe answer: ask.
@MainActor
public final class UserDefaultsSessionClosePreferences: SessionClosePreferences {
  private let key = "sessions.close.skipsRunningAgentConfirmation.v1"
  private let setAsideKey = "sessions.close.onSetAside.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var confirmsStoppingRunningAgent: Bool {
    get { !defaults.bool(forKey: key) }
    set { defaults.set(!newValue, forKey: key) }
  }

  /// A value never written, or one this version does not know, reads as the question.
  public var setAsideClose: SetAsideClose {
    get { defaults.string(forKey: setAsideKey).flatMap(SetAsideClose.init(rawValue:)) ?? .ask }
    set { defaults.set(newValue.rawValue, forKey: setAsideKey) }
  }
}
