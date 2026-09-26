import Foundation
import VibeApplication

/// The names given to groups, in `folders.json` next to `sessions.json` (#27).
///
/// Text the user wrote, so it is kept in the data folder rather than in the preferences, which a
/// corrupted value can cost. A document that cannot be read is never written over: its names are
/// the only copy, and renaming is refused until it is readable again.
public actor FileFolderLabelStore: FolderLabelStore {
  static let currentSchemaVersion = 1

  private let url: URL

  public init(url: URL = FileFolderLabelStore.defaultURL()) {
    self.url = url
  }

  /// `folders.json` next to `sessions.json`.
  public static func defaultURL() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("folders.json", isDirectory: false)
  }

  public func labels() throws -> [SessionFolderKey: String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.schemaVersion == Self.currentSchemaVersion else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var labels: [SessionFolderKey: String] = [:]
    for entry in document.folders {
      guard let name = FolderLabel.normalized(entry.name) else { continue }
      labels[SessionFolderKey(path: entry.path)] = name
    }
    return labels
  }

  @discardableResult
  public func setLabel(_ label: String?, for folder: SessionFolderKey) throws
    -> [SessionFolderKey: String]
  {
    var labels = try labels()
    labels[folder] = label.flatMap(FolderLabel.normalized)
    let document = Document(
      schemaVersion: Self.currentSchemaVersion,
      folders: labels.sorted { $0.key < $1.key }.map { Entry(path: $0.key.path, name: $0.value) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try AtomicFileWriter.write(try encoder.encode(document), to: url)
    return labels
  }

  private struct Document: Codable {
    let schemaVersion: Int
    let folders: [Entry]
  }

  private struct Entry: Codable {
    let path: String
    let name: String
  }
}
