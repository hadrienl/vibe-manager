import Foundation
import VibeApplication

/// The recent folders live in the user defaults, beside the layout.
///
/// Like the layout, they are kept out of the session store: they are a shortcut of this Mac's
/// New Session sheet, and an unreadable preference must never cost the sessions anything.
public actor UserDefaultsRecentFolderStore: RecentFolderStore {
  private let key = "newSession.recentFolders.v1"
  private let defaults: UserDefaults

  /// The suite is named rather than passed, so tests get their own storage without handing a
  /// shared, non-sendable `UserDefaults` across an isolation boundary.
  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func load() -> RecentFolders? {
    guard let data = defaults.data(forKey: key) else { return nil }
    // Written once, then unreadable: an empty history rather than a new seeding, which would
    // bring back folders the user may have removed one by one.
    return (try? JSONDecoder().decode(RecentFolders.self, from: data)) ?? RecentFolders()
  }

  public func save(_ folders: RecentFolders) {
    guard let data = try? JSONEncoder().encode(folders) else { return }
    defaults.set(data, forKey: key)
  }
}
