import Foundation
import VibeApplication
import VibeDomain

/// The prompt templates, in `templates.json` next to `sessions.json`.
///
/// Written the way the session store is: the current file copied to `templates.backup.json`, the
/// new one written to a unique temporary file, synchronized, then moved over — so a crash leaves
/// the old version or the new one, never half of either. Files are `0600`, and a folder created
/// here is `0700`.
///
/// A file that cannot be read, or that a newer version wrote, is never written over: every change
/// is refused until it is dealt with, and its bytes stay the only copy of the user's templates.
public actor FilePromptTemplateRepository: PromptTemplateRepository {
  private let storeURL: URL
  private let backupURL: URL
  private let codec = PromptTemplateStoreCodec()
  private let beforeReplace: (@Sendable () throws -> Void)?

  public init(storeURL: URL = FilePromptTemplateRepository.defaultStoreURL()) {
    self.storeURL = storeURL
    backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
    beforeReplace = nil
  }

  init(storeURL: URL, beforeReplace: @escaping @Sendable () throws -> Void) {
    self.storeURL = storeURL
    backupURL = storeURL.deletingPathExtension().appendingPathExtension("backup.json")
    self.beforeReplace = beforeReplace
  }

  public static func defaultStoreURL() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("templates.json", isDirectory: false)
  }

  public nonisolated var fileURL: URL? { storeURL }

  public func library() throws -> PromptTemplateLibrary {
    try load()
  }

  @discardableResult
  public func update<Result: Sendable>(
    _ change: @Sendable (inout PromptTemplateLibrary) throws -> Result
  ) throws -> (PromptTemplateLibrary, Result) {
    var library = try load()
    let result = try change(&library)
    do {
      let data = try codec.encode(library)
      try commit(data)
    } catch let error as PromptTemplateStoreError {
      throw error
    } catch {
      throw PromptTemplateStoreError.cannotWrite(reason: Self.reason(error))
    }
    return (library, result)
  }

  private func load() throws -> PromptTemplateLibrary {
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
      return PromptTemplateLibrary()
    }
    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch {
      throw PromptTemplateStoreError.unreadable(reason: Self.reason(error))
    }
    do {
      return try codec.decode(data)
    } catch PromptTemplateCodecError.unsupportedVersion {
      throw PromptTemplateStoreError.unreadable(
        reason: "the file was written by a newer version of Vibe Manager.")
    } catch {
      throw PromptTemplateStoreError.unreadable(reason: "the file is damaged.")
    }
  }

  private func commit(_ data: Data) throws {
    try ensureDirectory()
    let manager = FileManager.default
    if manager.fileExists(atPath: storeURL.path) {
      try atomicWrite(try Data(contentsOf: storeURL), to: backupURL, interruptible: false)
    }
    try atomicWrite(data, to: storeURL, interruptible: true)
  }

  private func atomicWrite(_ data: Data, to destination: URL, interruptible: Bool) throws {
    let manager = FileManager.default
    let temporaryURL = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }

    guard
      manager.createFile(
        atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw PromptTemplateStoreError.cannotWrite(reason: "the folder is not writable.")
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

    if interruptible {
      try beforeReplace?()
    }
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: destination)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  /// Creates the folder with owner-only permissions. One that already exists keeps its own.
  private func ensureDirectory() throws {
    let directory = storeURL.deletingLastPathComponent()
    let manager = FileManager.default
    guard !manager.fileExists(atPath: directory.path) else { return }
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private static func reason(_ error: Error) -> String {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain {
      switch error.code {
      case NSFileWriteOutOfSpaceError: return "the disk is full."
      case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
        return "permission was denied."
      case NSFileWriteVolumeReadOnlyError: return "the volume is read-only."
      default: break
      }
    }
    if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return "the disk is full." }
    if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) {
      return "permission was denied."
    }
    return error.localizedDescription
  }
}
