import Foundation
import VibeApplication
import VibeDomain

/// The symbols and colours of the pickers (#199), in the user defaults beside the other interface
/// preferences. One that cannot be read is no preference at all: the shipped lists apply, and the
/// next change overwrites it.
@MainActor
public final class UserDefaultsSessionAppearancePaletteStore: SessionAppearancePaletteStore {
  private let key = "sessions.appearancePalette.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var palette: SessionAppearancePalette? {
    get {
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode(SessionAppearancePalette.self, from: $0)
      }
    }
    set {
      // The shipped lists are stored as nothing, so that they follow the application.
      guard let newValue, !newValue.isDefault,
        let data = try? JSONEncoder().encode(newValue)
      else {
        defaults.removeObject(forKey: key)
        return
      }
      defaults.set(data, forKey: key)
    }
  }
}
