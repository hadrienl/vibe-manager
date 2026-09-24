import Foundation
import VibeApplication
import VibeDomain

/// The runtime document, next to the session store and nothing like it.
///
/// No backup, no migration, no error: every way of failing to read it answers `nil`, which means
/// "no intention to honour". That is the whole reason it is a separate document — a damaged
/// record of one launch must never be able to make the sessions themselves unreadable, and losing
/// it costs a manual restart rather than a session.
///
/// It is not kept in the user defaults either: `cfprefsd` writes when it decides to, and this
/// document is written immediately before the application dies.
public actor FileSessionRuntimeStateStore: SessionRuntimeStateStore {
  /// 2 added the `detached` phase, the host and the sessions to resume beside it (ADR 0016). A
  /// build that only knows 1 reads a 2 as nothing to honour, which is the safe way to downgrade.
  private static let currentSchemaVersion = 2
  private static let readableSchemaVersions: Set<Int> = [1, 2]

  private let url: URL

  public init(url: URL = FileSessionRuntimeStateStore.defaultURL()) {
    self.url = url
  }

  public static func defaultURL() -> URL {
    FileSessionRepository.defaultStoreURL()
      .deletingLastPathComponent()
      .appendingPathComponent("runtime.json", isDirectory: false)
  }

  public func read() -> SessionRuntimeState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let document = try? Self.decoder().decode(Document.self, from: data) else { return nil }
    guard Self.readableSchemaVersions.contains(document.schemaVersion) else { return nil }
    return document.state
  }

  public func write(_ state: SessionRuntimeState) {
    let document = Document(schemaVersion: Self.currentSchemaVersion, state: state)
    guard let data = try? Self.encoder().encode(document) else { return }
    try? atomicWrite(data)
  }

  public func clear() {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Document

  /// The version sits outside the state so an unknown one can be recognised without decoding
  /// anything else — a document from a newer build is passed over, never guessed at.
  private struct Document: Codable {
    let schemaVersion: Int
    let state: SessionRuntimeState
  }

  private func atomicWrite(_ data: Data) throws {
    let manager = FileManager.default
    let directory = url.deletingLastPathComponent()
    if !manager.fileExists(atPath: directory.path) {
      try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }

    let temporaryURL = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporaryURL) }

    guard
      manager.createFile(
        atPath: temporaryURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else { return }

    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      try handle.write(contentsOf: data)
      // Written through, not queued: the last write this document ever gets is the one made on
      // the way out, and a quit that outran the page cache would leave the intention behind.
      try handle.synchronize()
    } catch {
      try? handle.close()
      throw error
    }
    try handle.close()

    if manager.fileExists(atPath: url.path) {
      _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
    } else {
      try manager.moveItem(at: temporaryURL, to: url)
    }
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // Fractional seconds, like the session store: the dates carried here are rounded to the
    // millisecond, and a format that dropped them would make every value differ from the one
    // written a moment earlier.
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(Self.timestampFormatter().string(from: date))
    }
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      guard let date = Self.timestampFormatter().date(from: value) else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(codingPath: decoder.codingPath, debugDescription: value)
        )
      }
      return date
    }
    return decoder
  }

  /// Built per call rather than held in a static: `ISO8601DateFormatter` is not `Sendable`, and
  /// a shared instance would be global mutable state for the sake of two writes per session.
  private static func timestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}
