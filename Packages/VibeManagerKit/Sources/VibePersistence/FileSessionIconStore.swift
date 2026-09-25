import Foundation
import VibeApplication
import VibeDomain

/// The project icons of the sessions: `Icons/<sha256>.png` next to `sessions.json` (#27).
///
/// Named by their content, so every session of a folder shares one file and importing the same
/// icon again writes nothing. The source file is never referred to: moving or deleting it changes
/// nothing on screen. Nothing is removed here either, for the reason notes are kept — a store
/// restored from its backup can bring back a session that names an icon.
public actor FileSessionIconStore: SessionIconStore {
  /// The importer never produces more, and a file larger than that was not written here.
  public static let byteLimit = 64 * 1024

  private let directory: URL

  public init(directory: URL = FileSessionIconStore.defaultDirectory()) {
    self.directory = directory
  }

  /// `Icons/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Icons", isDirectory: true)
  }

  public func save(_ icon: ProjectIcon) throws {
    guard icon.pngData.count <= Self.byteLimit else {
      throw SessionIconStoreError.tooLarge(byteCount: icon.pngData.count)
    }
    let destination = fileURL(for: icon.id)
    // Same name, same bytes: the file is already the right one.
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    try AtomicFileWriter.write(icon.pngData, to: destination)
  }

  public func pngData(for id: SessionIconID) -> Data? {
    let url = fileURL(for: id)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= Self.byteLimit
    else { return nil }
    return try? Data(contentsOf: url)
  }

  public nonisolated func fileURL(for id: SessionIconID) -> URL {
    directory.appendingPathComponent("\(id.sha256).png", isDirectory: false)
  }
}

public enum SessionIconStoreError: Error, Equatable, Sendable {
  case tooLarge(byteCount: Int)
}
