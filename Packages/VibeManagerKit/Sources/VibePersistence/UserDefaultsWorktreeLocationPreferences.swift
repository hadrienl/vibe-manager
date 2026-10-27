import Foundation
import VibeApplication
import VibeDomain

/// Settings › Worktrees (#432): a preference of this Mac, as JSON. Absent or unreadable, the
/// default path and no exception.
@MainActor
public final class UserDefaultsWorktreeLocationPreferences: WorktreeLocationPreferences {
  private let defaults: UserDefaults
  private let key = "worktrees.locations.v1"

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var worktreeLocations: WorktreeLocationSettings {
    get {
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode(WorktreeLocationSettings.self, from: $0)
      } ?? WorktreeLocationSettings()
    }
    set {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      defaults.set(try? encoder.encode(newValue), forKey: key)
    }
  }
}
