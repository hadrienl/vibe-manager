import AppKit
import Observation
import VibeApplication
import VibeDomain

/// The project icons the badges draw, read once from the store and kept (#27).
///
/// Read away from the main thread, on the first request: a badge draws its symbol and its colour
/// until its image arrives, and keeps them if the file is gone.
@MainActor
@Observable
public final class SessionIconLibrary {
  private var images: [SessionIconID: NSImage] = [:]
  @ObservationIgnored private var requested: Set<SessionIconID> = []
  @ObservationIgnored private let store: (any SessionIconStore)?

  public init(store: (any SessionIconStore)? = nil) {
    self.store = store
  }

  /// The image, or `nil` while it is read or when it cannot be.
  public func image(for id: SessionIconID?) -> NSImage? {
    guard let id else { return nil }
    if let image = images[id] { return image }
    guard let store, !requested.contains(id) else { return nil }
    requested.insert(id)
    Task { [weak self] in
      guard let data = await store.pngData(for: id), let image = NSImage(data: data) else {
        return
      }
      self?.images[id] = image
    }
    return nil
  }

  /// An icon found for a draft, shown before it is stored.
  public func insert(_ icon: ProjectIcon) {
    guard images[icon.id] == nil, let image = NSImage(data: icon.pngData) else { return }
    images[icon.id] = image
  }
}
