import Foundation
import VibeApplication

/// The dictation's model and language, kept across launches (#340). A key never written, or one
/// this build cannot read, is the default: the large model, the language heard.
@MainActor
public final class UserDefaultsDictationSettingsStore: DictationSettingsStore {
  private let key = "dictation.settings.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var settings: DictationSettings {
    get {
      defaults.data(forKey: key)
        .flatMap { try? JSONDecoder().decode(DictationSettings.self, from: $0) }
        ?? DictationSettings()
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
    }
  }
}
