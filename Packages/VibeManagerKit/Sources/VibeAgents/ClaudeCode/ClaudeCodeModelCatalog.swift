import Foundation
import VibeApplication

public protocol ClaudeCodeModelCatalogSource: Sendable {
  func models() async -> [AgentModel]
}

/// Reads the model catalog the CLI caches for the signed in account.
///
/// Nothing is hard coded: which models exist, and which ones this account may use, change
/// faster than a released application. A machine where Claude Code has never run offers no
/// model until it has, which is honest rather than wrong.
public struct ClaudeCodeModelCatalog: ClaudeCodeModelCatalogSource {
  public static let defaultMaximumCacheByteCount = 8 * 1024 * 1024
  /// The surface the CLI writes for itself; `ccd` belongs to the desktop application.
  static let preferredSurface = "cc"
  static let maximumModelCount = 200
  /// How many files may be opened before giving up. The freshest one normally answers first,
  /// so this only bounds a directory that has gone wrong.
  static let maximumReadCount = 8

  private let directory: URL
  private let maximumCacheByteCount: Int

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    maximumCacheByteCount: Int = ClaudeCodeModelCatalog.defaultMaximumCacheByteCount
  ) {
    self.init(
      directory: ClaudeCodeHome.modelCatalogDirectory(environment: environment),
      maximumCacheByteCount: maximumCacheByteCount
    )
  }

  public init(
    directory: URL,
    maximumCacheByteCount: Int = ClaudeCodeModelCatalog.defaultMaximumCacheByteCount
  ) {
    self.directory = directory
    self.maximumCacheByteCount = maximumCacheByteCount
  }

  public func models() async -> [AgentModel] {
    guard let entries = bestCatalog() else { return [] }

    // `main` is what the CLI puts in front of its own user; `overflow` holds the older models
    // it still accepts. Both are offered, in that order.
    let ordered = entries.filter { $0.section == "main" } + entries.filter { $0.section != "main" }

    var seen: Set<String> = []
    var models: [AgentModel] = []
    for entry in ordered {
      let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (try? ClaudeCodeArgumentBuilder.validatedModelID(id)) != nil else { continue }
      guard seen.insert(id).inserted else { continue }
      let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
      models.append(
        AgentModel(
          id: id,
          displayName: name.map { $0.isEmpty ? id : $0 } ?? id,
          // Passing no model at all is the explicit choice that leaves the user's own setting
          // in charge, so no entry is ever marked as the default.
          isDefault: false
        )
      )
      if models.count == Self.maximumModelCount { break }
    }
    return models
  }

  /// The freshest catalog written for the CLI's own surface, or, failing that, the freshest one
  /// of any surface: the identifiers speak the same vocabulary, and something beats nothing.
  ///
  /// Files are opened newest first and reading stops at the first usable one, so the normal
  /// case costs a single read whatever the directory has accumulated.
  private func bestCatalog() -> [Cache.Entry]? {
    var fallback: [Cache.Entry]?
    var reads = 0

    for url in candidateURLs() {
      guard reads < Self.maximumReadCount else { break }
      reads += 1
      guard let data = readCache(at: url) else { continue }
      guard let cache = try? JSONDecoder().decode(Cache.self, from: data), !cache.models.isEmpty
      else {
        continue
      }
      // Candidates are ordered freshest first, so the first match of each kind is the freshest
      // of its kind.
      if cache.surface == Self.preferredSurface { return cache.models }
      if fallback == nil { fallback = cache.models }
    }
    return fallback
  }

  /// The CLI's own surface first, then newest first. The names are random hashes, so their
  /// order says nothing beyond the surface suffix, and only the decoded `surface` is trusted:
  /// the name merely decides what is opened first.
  private func candidateURLs() -> [URL] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )) ?? []

    return
      contents
      .filter { $0.pathExtension == "json" }
      .map { url -> (url: URL, looksPreferred: Bool, modifiedAt: Date) in
        let values = try? url.resourceValues(forKeys: Set(keys))
        return (
          url,
          url.lastPathComponent.hasSuffix("-\(Self.preferredSurface).json"),
          values?.contentModificationDate ?? .distantPast
        )
      }
      .sorted { left, right in
        if left.looksPreferred != right.looksPreferred { return left.looksPreferred }
        if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
        return left.url.lastPathComponent < right.url.lastPathComponent
      }
      .map(\.url)
  }

  private func readCache(at url: URL) -> Data? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      size.intValue > 0, size.intValue <= maximumCacheByteCount
    else {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  private struct Cache: Decodable {
    let surface: String?
    let models: [Entry]

    private enum CodingKeys: String, CodingKey {
      case catalog
    }

    private enum CatalogKeys: String, CodingKey {
      case surface
      case config
    }

    private enum ConfigKeys: String, CodingKey {
      case models
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let catalog = try container.nestedContainer(keyedBy: CatalogKeys.self, forKey: .catalog)
      surface = try? catalog.decode(String.self, forKey: .surface)
      let config = try catalog.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
      models = try config.decode([FailableEntry].self, forKey: .models).compactMap(\.entry)
    }

    /// One malformed entry must not discard the whole catalog.
    struct FailableEntry: Decodable {
      let entry: Entry?

      init(from decoder: Decoder) throws {
        entry = try? Entry(from: decoder)
      }
    }

    struct Entry: Decodable {
      let id: String
      let name: String?
      let section: String?
    }
  }
}
