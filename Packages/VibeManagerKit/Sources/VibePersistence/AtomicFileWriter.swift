import Foundation

/// Writes a file the way the stores do: a unique temporary file in the same folder, synchronized,
/// then moved over. A crash leaves the old version or the new one, never half of either. The file
/// is `0600`, and a folder created on the way `0700`; one that already exists keeps its own mode.
enum AtomicFileWriter {
  static func write(_ data: Data, to destination: URL) throws {
    let manager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    if !manager.fileExists(atPath: directory.path) {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let temporaryURL = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }

    guard
      manager.createFile(
        atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
    }
    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
    } catch {
      try? handle.close()
      throw error
    }
    try handle.close()

    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: destination)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }
}
