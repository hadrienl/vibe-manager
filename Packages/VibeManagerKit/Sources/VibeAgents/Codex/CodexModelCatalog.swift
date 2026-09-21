import Foundation
import VibeApplication

public protocol CodexModelCatalogSource: Sendable {
  func models() async -> [AgentModel]
}

/// Reads the model list the Codex CLI already cached for itself.
///
/// No network call and no process: `models_cache.json` is written by `codex` on its own
/// schedule. It is an internal file of the CLI, not an API, so every failure to read or
/// decode it falls back to "no choice offered", which the interface renders as the model
/// configured in `config.toml`. Hard coding slugs here would age worse: model names change
/// between two releases of the CLI, and a stale list would offer models that no longer exist.
public struct CodexModelCatalog: CodexModelCatalogSource {
  /// The cache observed in the wild is a few hundred kilobytes. The ceiling only exists so a
  /// corrupted or hostile file cannot be pulled entirely into memory.
  public static let defaultMaximumCacheByteCount = 8 * 1024 * 1024
  /// A picker is unusable past a few dozen entries, and a longer list means a broken file.
  static let maximumModelCount = 200

  private let cacheURL: URL
  private let maximumCacheByteCount: Int

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    maximumCacheByteCount: Int = CodexModelCatalog.defaultMaximumCacheByteCount
  ) {
    self.init(
      cacheURL: CodexHome.modelsCacheURL(environment: environment),
      maximumCacheByteCount: maximumCacheByteCount
    )
  }

  public init(
    cacheURL: URL,
    maximumCacheByteCount: Int = CodexModelCatalog.defaultMaximumCacheByteCount
  ) {
    self.cacheURL = cacheURL
    self.maximumCacheByteCount = maximumCacheByteCount
  }

  public func models() async -> [AgentModel] {
    guard let data = readCache() else { return [] }
    guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }

    var seen: Set<String> = []
    var models: [AgentModel] = []
    for entry in cache.models {
      let slug = entry.slug.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !slug.isEmpty, (try? CodexArgumentBuilder.validatedModelID(slug)) != nil else {
        continue
      }
      guard seen.insert(slug).inserted else { continue }
      let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
      models.append(
        AgentModel(
          id: slug,
          displayName: name.map { $0.isEmpty ? slug : $0 } ?? slug,
          // No model is marked as the default: leaving the choice empty means "whatever
          // `config.toml` says", which is the user's own decision and must not be overridden.
          isDefault: false
        )
      )
      if models.count == Self.maximumModelCount { break }
    }
    return models
  }

  private func readCache() -> Data? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
      let size = attributes[.size] as? NSNumber,
      size.intValue > 0, size.intValue <= maximumCacheByteCount
    else {
      return nil
    }
    // Read, not mapped: the CLI rewrites this file on its own schedule, and a mapping whose
    // backing file is truncated mid-read faults instead of failing. The size is bounded above.
    return try? Data(contentsOf: cacheURL)
  }

  private struct Cache: Decodable {
    let models: [Entry]

    private enum CodingKeys: String, CodingKey {
      case models
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // One malformed entry must not discard the whole list: this file belongs to another
      // program, which is free to add or reshape fields between two of its releases.
      models = try container.decode([FailableEntry].self, forKey: .models).compactMap(\.entry)
    }

    struct FailableEntry: Decodable {
      let entry: Entry?

      init(from decoder: Decoder) throws {
        entry = try? Entry(from: decoder)
      }
    }

    struct Entry: Decodable {
      let slug: String
      let displayName: String?

      private enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
      }
    }
  }
}
