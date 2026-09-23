import Foundation
import VibeApplication

/// The editor chosen in the settings, kept across launches. A key never written, or one this build
/// cannot read, is no choice at all: files are then only revealed.
@MainActor
public final class UserDefaultsFileOpeningPreferences: FileOpeningPreferences {
  private let key = "inspector.fileOpening.editor.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var editor: EditorChoice? {
    get {
      defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(EditorChoice.self, from: $0) }
    }
    set {
      if let newValue, let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
