import Foundation
import VibeApplication
import VibeDomain

/// The ticket resolvers (#89), in `ticket-resolvers.json` next to `sessions.json`.
///
/// No file means the shipped presets. A file that cannot be read, or that a newer version wrote,
/// is never written over: saving is refused until it is dealt with, and its bytes stay the only
/// copy of the user's resolvers.
public actor FileTicketResolverRepository: TicketResolverRepository {
  static let schema = 1

  private let storeURL: URL

  public init(storeURL: URL = FileTicketResolverRepository.defaultStoreURL()) {
    self.storeURL = storeURL
  }

  public static func defaultStoreURL() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("ticket-resolvers.json", isDirectory: false)
  }

  public nonisolated var fileURL: URL? { storeURL }

  private struct Stored: Codable {
    var schema: Int
    var knownPresets: [String]
    var resolvers: [TicketResolver]
  }

  public func document() throws -> TicketResolverDocument {
    guard FileManager.default.fileExists(atPath: storeURL.path) else { return .shipped }
    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch {
      throw TicketResolverStoreError.unreadable(reason: error.localizedDescription)
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      throw TicketResolverStoreError.unreadable(
        reason: String(localized: "the file is damaged.", bundle: .module))
    }
    guard stored.schema <= Self.schema else {
      throw TicketResolverStoreError.unreadable(
        reason: String(
          localized: "the file was written by a newer version of Vibe Manager.", bundle: .module))
    }
    return TicketResolverDocument(
      resolvers: stored.resolvers, knownPresets: Set(stored.knownPresets))
  }

  public func save(_ resolvers: [TicketResolver]) throws {
    // Refused over a file that cannot be read: its bytes would be lost.
    let previous = try document()
    let known = previous.knownPresets.union(TicketResolverPresets.all.compactMap(\.preset?.id))
    let stored = Stored(schema: Self.schema, knownPresets: known.sorted(), resolvers: resolvers)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      try AtomicFileWriter.write(try encoder.encode(stored), to: storeURL)
    } catch {
      throw TicketResolverStoreError.cannotWrite(reason: error.localizedDescription)
    }
  }
}
