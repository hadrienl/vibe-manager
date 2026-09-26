import Foundation
import VibeApplication

/// Whether sessions summarize themselves, in the user defaults of this copy of the application.
public final class UserDefaultsJournalPreferences: JournalPreferences {
  private let key = "journal.summaries.enabled.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var summariesEnabled: Bool {
    get { defaults.object(forKey: key) as? Bool ?? true }
    set { defaults.set(newValue, forKey: key) }
  }
}
