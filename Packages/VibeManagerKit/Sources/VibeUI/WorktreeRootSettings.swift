import Foundation
import Observation
import VibeApplication

/// The worktree root, as the settings window shows and changes it.
@MainActor
@Observable
public final class WorktreeRootSettings {
  public private(set) var path: String?
  private let store: any WorktreeRootStoring

  public init(store: any WorktreeRootStoring) {
    self.store = store
  }

  public func load() async {
    path = await store.worktreeRootPath()
  }

  /// Takes a folder designated through the open panel, which is also what grants access to it.
  public func choose(_ path: String) async {
    await store.setWorktreeRootPath(path)
    await load()
  }

  public func reset() async {
    await store.resetWorktreeRootPath()
    await load()
  }

  public var isDefault: Bool {
    path == FixedWorktreeRoot.defaultPath
  }
}
