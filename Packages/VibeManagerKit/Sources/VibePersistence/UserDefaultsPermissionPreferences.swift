import Foundation
import VibeApplication

/// The permission steps the user has already answered, kept with the other interface preferences.
///
/// Only the answer is stored, with the code identity that gave it, never the access itself:
/// whether Full Disk Access is granted is read from the system, so an access turned off in System
/// Settings cannot leave a stale "yes" behind in the preferences.
///
/// The first version of this key was a plain boolean, and it outlived the change of the bundle
/// identifier that made TCC forget the access (#76). It is read as no answer at all, so the step
/// comes back once to everyone who had dismissed it without having the access — exactly the users
/// that change stranded. It is left in place, so an earlier build going back to it still reads
/// what it wrote.
public actor UserDefaultsPermissionPreferences: PermissionPreferences {
  private let key = "permissions.fullDiskAccess.stepAnswer.v2"
  private let defaults: UserDefaults

  /// The suite is named rather than passed, so tests get their own storage without handing a
  /// shared, non-sendable `UserDefaults` across an isolation boundary.
  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func fullDiskAccessStepAnswer() -> CodeIdentityFingerprint? {
    defaults.string(forKey: key).map(CodeIdentityFingerprint.init(rawValue:))
  }

  public func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) {
    defaults.set(identity.rawValue, forKey: key)
  }

  /// Never written by the application: `-permissions.fullDiskAccess.stepSuppressed YES` on the
  /// command line, as the interface smoke test passes it.
  public func isFullDiskAccessStepSuppressed() -> Bool {
    defaults.bool(forKey: "permissions.fullDiskAccess.stepSuppressed")
  }
}
