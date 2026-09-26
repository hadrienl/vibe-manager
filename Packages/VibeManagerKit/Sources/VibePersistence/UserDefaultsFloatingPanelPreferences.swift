import Foundation
import VibeApplication

/// What the user chose about the floating panel (#41), kept across launches. A key never written
/// reads as its default: the panel off, hidden when idle, unfolded, at its default place.
@MainActor
public final class UserDefaultsFloatingPanelPreferences: FloatingPanelPreferences {
  private enum Key {
    static let showsFloatingPanel = "requests.floatingPanel.shown.v1"
    static let idle = "requests.floatingPanel.idle.v1"
    static let isCollapsed = "requests.floatingPanel.collapsed.v1"
    static let anchors = "requests.floatingPanel.anchors.v1"
  }

  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var showsFloatingPanel: Bool {
    get { defaults.bool(forKey: Key.showsFloatingPanel) }
    set { defaults.set(newValue, forKey: Key.showsFloatingPanel) }
  }

  public var idle: FloatingPanelIdle {
    get { defaults.string(forKey: Key.idle).flatMap(FloatingPanelIdle.init(rawValue:)) ?? .hidden }
    set { defaults.set(newValue.rawValue, forKey: Key.idle) }
  }

  public var isCollapsed: Bool {
    get { defaults.bool(forKey: Key.isCollapsed) }
    set { defaults.set(newValue, forKey: Key.isCollapsed) }
  }

  public var anchors: [String: FloatingPanelAnchor] {
    get {
      guard let data = defaults.data(forKey: Key.anchors) else { return [:] }
      return (try? JSONDecoder().decode([String: FloatingPanelAnchor].self, from: data)) ?? [:]
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.anchors) }
  }
}
