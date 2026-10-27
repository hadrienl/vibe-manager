import Foundation
import VibeApplication

/// The voice that reads the answers, and its language, kept across launches (#357). A key never
/// written, or one this build cannot read, is the default.
@MainActor
public final class UserDefaultsSpeechSettingsStore: SpeechSettingsStore {
  private let key = "speech.settings.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var settings: SpeechSettings {
    get {
      defaults.data(forKey: key)
        .flatMap { try? JSONDecoder().decode(SpeechSettings.self, from: $0) }
        ?? SpeechSettings()
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
    }
  }
}
