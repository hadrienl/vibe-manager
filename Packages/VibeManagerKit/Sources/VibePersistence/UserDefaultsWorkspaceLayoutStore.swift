import Foundation
import VibeApplication

/// The layout lives in the user defaults, next to the other interface preferences.
///
/// It is not written into the session store: a corrupted or outdated layout must never be able
/// to make the sessions themselves unreadable, and losing it costs the user one drag.
public actor UserDefaultsWorkspaceLayoutStore: WorkspaceLayoutStore {
  private let key = "workspace.layout.v1"
  private let defaults: UserDefaults

  /// The suite is named rather than passed, so tests get their own storage without handing a
  /// shared, non-sendable `UserDefaults` across an isolation boundary.
  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func load() -> WorkspaceLayout {
    guard let data = defaults.data(forKey: key),
      let layout = try? JSONDecoder().decode(WorkspaceLayout.self, from: data)
    else {
      // An unreadable preference is not an error the user has to deal with: the workspace opens
      // with its default columns, and the next change overwrites it.
      return WorkspaceLayout()
    }
    return layout
  }

  public func save(_ layout: WorkspaceLayout) {
    guard let data = try? JSONEncoder().encode(layout) else { return }
    defaults.set(data, forKey: key)
  }
}

/// The layout of a workspace that keeps nothing, for previews and tests.
public actor InMemoryWorkspaceLayoutStore: WorkspaceLayoutStore {
  private var layout: WorkspaceLayout
  public private(set) var saveCount = 0

  public init(layout: WorkspaceLayout = WorkspaceLayout()) {
    self.layout = layout
  }

  public func load() -> WorkspaceLayout {
    layout
  }

  public func save(_ layout: WorkspaceLayout) {
    self.layout = layout
    saveCount += 1
  }
}
