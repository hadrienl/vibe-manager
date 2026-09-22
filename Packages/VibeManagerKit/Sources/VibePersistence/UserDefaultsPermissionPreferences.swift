import Foundation
import VibeApplication

/// The permission steps the user has already answered, kept with the other interface preferences.
///
/// Only the answer is stored, never the access itself: whether Full Disk Access is granted is
/// probed at every launch, so an access turned off in System Settings cannot leave a stale "yes"
/// behind in the preferences.
public actor UserDefaultsPermissionPreferences: PermissionPreferences {
  private let key = "permissions.fullDiskAccess.stepDismissed.v1"
  private let defaults: UserDefaults

  /// The suite is named rather than passed, so tests get their own storage without handing a
  /// shared, non-sendable `UserDefaults` across an isolation boundary.
  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func isFullDiskAccessStepDismissed() -> Bool {
    defaults.bool(forKey: key)
  }

  public func dismissFullDiskAccessStep() {
    defaults.set(true, forKey: key)
  }
}
