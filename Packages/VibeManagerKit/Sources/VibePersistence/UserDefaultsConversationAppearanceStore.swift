import Foundation
import VibeApplication

/// The Conversation settings (#38), kept in the user defaults next to the other interface
/// preferences. One that cannot be read is no preference at all: the defaults apply, and the next
/// change overwrites it.
@MainActor
public final class UserDefaultsConversationAppearanceStore: ConversationAppearanceStore {
  private let key = "conversation.appearance.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var appearance: ConversationAppearance {
    get {
      defaults.data(forKey: key).flatMap {
        try? JSONDecoder().decode(ConversationAppearance.self, from: $0)
      } ?? ConversationAppearance()
    }
    set {
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: key)
    }
  }
}
