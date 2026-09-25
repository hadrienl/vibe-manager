import Foundation
import VibeApplication
import VibeDomain

/// The notes of each session, one plain-text file per session.
///
/// `Notes/<session-uuid>.txt`, UTF-8, the text exactly as typed: a file anyone can read with `cat`
/// and recover by hand. Written the way the session store is — a unique temporary file in the same
/// folder, synchronized, then moved over — so a crash leaves the old version or the new one, never
/// half of either. Files are `0600`, and a folder created here is `0700`.
///
/// A file that cannot be read is never written over: its bytes are the only copy of what the user
/// wrote. A file that no session names any more is left where it is: a store restored from its
/// backup can bring that session back.
public actor FileSessionNotesStore: SessionNotesStore {
  private let directory: URL
  private let beforeReplace: (@Sendable () throws -> Void)?
  private let diagnostics: Diagnostics

  public init(
    directory: URL = FileSessionNotesStore.defaultDirectory(),
    diagnostics: Diagnostics = .disabled
  ) {
    self.directory = directory
    beforeReplace = nil
    self.diagnostics = diagnostics
  }

  init(directory: URL, beforeReplace: @escaping @Sendable () throws -> Void) {
    self.directory = directory
    self.beforeReplace = beforeReplace
    diagnostics = .disabled
  }

  /// `Notes/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Notes", isDirectory: true)
  }

  public func notes(for id: SessionID) throws -> SessionNotes {
    try read(id) ?? .empty
  }

  @discardableResult
  public func save(_ text: String, for id: SessionID) throws -> SessionNotes {
    let current = try read(id)
    let currentCount = current?.text.utf8.count ?? 0
    guard SessionNotesLimits.accepts(text, replacing: currentCount) else {
      throw SessionNotesError.tooLarge(
        byteCount: text.utf8.count, limit: SessionNotesLimits.byteLimit)
    }
    return try write(text, for: id)
  }

  public func importNotes(_ text: String, for id: SessionID) throws {
    if let current = try read(id), !current.text.isEmpty { return }
    _ = try write(text, for: id)
  }

  public func allNotes() -> [SessionID: String] {
    let manager = FileManager.default
    guard
      let names = try? manager.contentsOfDirectory(atPath: directory.path)
    else { return [:] }
    var result: [SessionID: String] = [:]
    for name in names where name.hasSuffix(".txt") && !name.hasPrefix(".") {
      guard let uuid = UUID(uuidString: String(name.dropLast(4))) else { continue }
      let id = SessionID(rawValue: uuid)
      guard let notes = try? read(id), !notes.text.isEmpty else { continue }
      result[id] = notes.text
    }
    return result
  }

  // MARK: - Files

  private func url(for id: SessionID) -> URL {
    fileURL(for: id)
  }

  /// Where a session's notes are, whether or not they exist yet.
  public nonisolated func fileURL(for id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).txt", isDirectory: false)
  }

  /// The notes on disk, `nil` when there is no file.
  private func read(_ id: SessionID) throws -> SessionNotes? {
    let url = url(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      note("notes.readFailed", id, error)
      throw SessionNotesError.unreadable(reason: Self.reason(error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw SessionNotesError.unreadable(reason: "the file is not UTF-8 text.")
    }
    return SessionNotes(text: text, modifiedAt: modificationDate(of: url))
  }

  private func write(_ text: String, for id: SessionID) throws -> SessionNotes {
    let destination = url(for: id)
    let manager = FileManager.default
    do {
      guard !text.isEmpty else {
        // One way to say "no notes": no file.
        if manager.fileExists(atPath: destination.path) {
          try manager.removeItem(at: destination)
        }
        return .empty
      }
      try ensureDirectory()
      try atomicWrite(Data(text.utf8), to: destination)
    } catch let error as SessionNotesError {
      note("notes.writeFailed", id, error)
      throw error
    } catch {
      note("notes.writeFailed", id, error)
      throw SessionNotesError.cannotWrite(reason: Self.reason(error))
    }
    return SessionNotes(text: text, modifiedAt: modificationDate(of: destination) ?? Date())
  }

  /// Which session, and the `errno`: never the text, nor the file's path.
  private func note(_ name: StaticString, _ id: SessionID, _ error: any Error) {
    var fields: [(name: StaticString, value: DiagnosticValue)] = [
      ("session", diagnostics.pseudonym(id))
    ]
    if let code = DiagnosticValue.posixCode(of: error) { fields.append(("errno", code)) }
    diagnostics.log.record(DiagnosticEvent(.notes, .error, name, fields: fields))
  }

  private func atomicWrite(_ data: Data, to destination: URL) throws {
    let manager = FileManager.default
    let temporaryURL = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }

    guard
      manager.createFile(
        atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw SessionNotesError.cannotWrite(reason: "the notes folder is not writable.")
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

    try beforeReplace?()
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: destination)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  /// Creates the folder with owner-only permissions. One that already exists keeps its own.
  private func ensureDirectory() throws {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: directory.path) else { return }
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private func modificationDate(of url: URL) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }

  /// The system's own sentence, without the file name: the notes are named by the interface, and
  /// a path made of a UUID tells the user nothing.
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
