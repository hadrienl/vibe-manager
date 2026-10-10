import Foundation

/// A `.zip` the user chose or dropped — an avatar's (#41), a theme's (#361) —, read with the bound
/// of the archive itself: a larger file is not read at all.
public enum ChosenArchive {
  /// No archive weighs more: a dozen images, or a theme with its picture and a few fonts.
  public static let maximumSize = 30 * 1024 * 1024

  public enum Problem: Error, Hashable, Sendable {
    case unreadable
    case tooLarge
  }

  /// The bytes of the archive at `url`, a security-scoped one included.
  public static func contents(of url: URL) -> Result<Data, Problem> {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      return .failure(.unreadable)
    }
    guard size <= maximumSize else { return .failure(.tooLarge) }
    guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
    return .success(data)
  }
}
