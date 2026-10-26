import Foundation
import VibeApplication

/// The synthesis of the archive reports (#408), on or off, in the application's defaults.
public final class UserDefaultsArchiveReportPreferences: ArchiveReportPreferences {
  private let key = "archive.reports.synthesis.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var synthesisEnabled: Bool? {
    get { defaults.object(forKey: key) as? Bool }
    set { defaults.set(newValue, forKey: key) }
  }
}
