import Foundation
import VibeApplication

/// Where the worktrees go, kept with the other interface preferences.
public actor UserDefaultsWorktreeRootStore: WorktreeRootStoring {
  private let key = "workspace.worktreeRoot.v1"
  private let defaults: UserDefaults
  private let defaultPath: String

  /// The suite is named rather than passed, so tests get their own storage without handing a
  /// shared, non-sendable `UserDefaults` across an isolation boundary.
  public init(suiteName: String? = nil, defaultPath: String = FixedWorktreeRoot.defaultPath) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.defaultPath = defaultPath
  }

  public func worktreeRootPath() -> String {
    guard let stored = defaults.string(forKey: key), stored.hasPrefix("/") else {
      return defaultPath
    }
    return stored
  }

  public func setWorktreeRootPath(_ path: String) {
    guard path.hasPrefix("/") else { return }
    defaults.set(path, forKey: key)
  }

  public func resetWorktreeRootPath() {
    defaults.removeObject(forKey: key)
  }
}
