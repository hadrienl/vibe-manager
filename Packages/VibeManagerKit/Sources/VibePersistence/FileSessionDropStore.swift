import Foundation
import VibeApplication
import VibeDomain

/// `Drops/<session>/` next to `sessions.json` (#42).
///
/// Not `$TMPDIR`: macOS empties it after three days, while a session can last longer, be left
/// running without the application and be resumed; and a copy pointed at its own data directory
/// would share it. The data directory is not a place TCC guards, so an agent reads what is here
/// without asking, Full Disk Access or not. Owner only, like the rest of the directory.
public actor FileSessionDropStore: SessionDropStore {
  private let directory: URL

  public init(directory: URL = FileSessionDropStore.defaultDirectory()) {
    self.directory = directory
  }

  /// `Drops/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Drops", isDirectory: true)
  }

  public func save(_ data: Data, suggestedName: String, for id: SessionID) throws -> URL {
    let destination = try destination(for: suggestedName, in: id)
    try AtomicFileWriter.write(data, to: destination)
    return destination
  }

  public func copy(_ file: URL, suggestedName: String, for id: SessionID) throws -> URL {
    let destination = try destination(for: suggestedName, in: id)
    try FileManager.default.copyItem(at: file, to: destination)
    return destination
  }

  public func remove(_ id: SessionID) {
    try? FileManager.default.removeItem(at: folder(for: id))
  }

  public func sweep(keeping ids: Set<SessionID>) {
    let kept = Set(ids.map(\.rawValue))
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return }
    // Only the folders this store names: anything else found here is not its to delete.
    for name in names {
      guard let uuid = UUID(uuidString: name), !kept.contains(uuid) else { continue }
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private func folder(for id: SessionID) -> URL {
    directory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
  }

  private func destination(for suggestedName: String, in id: SessionID) throws -> URL {
    let folder = folder(for: id)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = DropNaming.unique(
      DropNaming.sanitized(
        suggestedName,
        fallback: DropNaming.timestampName(at: Date(), fileExtension: "")),
      isTaken: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
    return folder.appendingPathComponent(name, isDirectory: false)
  }
}
