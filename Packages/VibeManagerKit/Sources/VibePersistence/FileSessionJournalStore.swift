import Foundation
import VibeApplication
import VibeDomain

/// The journal of each session, one JSON file per session (#36).
///
/// `Journal/<session-uuid>.json`, next to the notes and under the same rules (ADR 0016): written to
/// a unique temporary file in the same folder, synchronized, then moved over; `0600` files in a
/// `0700` folder. A file that cannot be read is never written over, and one no session names any
/// more is left where it is.
public actor FileSessionJournalStore: SessionJournalStore {
  /// The most a journal may weigh on disk. Its bounds keep it well under half of it.
  public static let byteLimit = 4 << 20

  private let directory: URL
  /// Sessions whose file could not be read: never written over for the length of the run.
  private var unreadable: Set<SessionID> = []

  public init(directory: URL = FileSessionJournalStore.defaultDirectory()) {
    self.directory = directory
  }

  /// `Journal/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Journal", isDirectory: true)
  }

  public nonisolated func fileURL(for id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
  }

  public func journal(for id: SessionID) throws -> SessionJournal? {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      let journal = try JSONDecoder.journal.decode(SessionJournal.self, from: data)
      // A journal written by a later version is read, never rewritten by this one.
      guard journal.schema <= SessionJournal.schemaVersion else {
        unreadable.insert(id)
        return journal
      }
      unreadable.remove(id)
      return journal
    } catch {
      unreadable.insert(id)
      throw SessionJournalStoreError.unreadable
    }
  }

  public func save(_ journal: SessionJournal, for id: SessionID) throws {
    guard !unreadable.contains(id) else { throw SessionJournalStoreError.unreadable }
    let destination = fileURL(for: id)
    let manager = FileManager.default
    do {
      let data = try JSONEncoder.journal.encode(journal)
      guard data.count <= Self.byteLimit else {
        throw SessionJournalStoreError.cannotWrite("too large")
      }
      if !manager.fileExists(atPath: directory.path) {
        try manager.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      let temporary = directory.appendingPathComponent(
        ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
      defer { try? manager.removeItem(at: temporary) }
      guard
        manager.createFile(
          atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw SessionJournalStoreError.cannotWrite("not writable") }
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
      } catch {
        try? handle.close()
        throw error
      }
      try handle.close()
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch let error as SessionJournalStoreError {
      throw error
    } catch {
      throw SessionJournalStoreError.cannotWrite((error as NSError).localizedDescription)
    }
  }
}

extension JSONEncoder {
  fileprivate static var journal: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var journal: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
