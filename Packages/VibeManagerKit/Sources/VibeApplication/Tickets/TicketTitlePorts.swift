import Foundation
import VibeDomain

/// The resolvers as they are kept: in the user's order, with the presets that existed when they
/// were saved, so that one the user deleted is not brought back and one shipped later is added.
public struct TicketResolverDocument: Hashable, Sendable {
  public var resolvers: [TicketResolver]
  public var knownPresets: Set<String>

  public init(resolvers: [TicketResolver], knownPresets: Set<String>) {
    self.resolvers = resolvers
    self.knownPresets = knownPresets
  }

  /// What a first launch finds: the presets, all of them on.
  public static var shipped: TicketResolverDocument {
    TicketResolverDocument(
      resolvers: TicketResolverPresets.all,
      knownPresets: Set(TicketResolverPresets.all.compactMap(\.preset?.id)))
  }

  /// The stored resolvers brought up to date with what this version ships.
  public var current: [TicketResolver] {
    TicketResolverPresets.merge(stored: resolvers, knownPresets: knownPresets)
  }
}

public enum TicketResolverStoreError: Error, Equatable, Sendable, LocalizedError {
  /// The file is there but could not be read, or was written by a newer version. It is never
  /// written over.
  case unreadable(reason: String)
  case cannotWrite(reason: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let reason):
      return String(localized: "Ticket resolvers couldn't be read: \(reason)", bundle: .module)
    case .cannotWrite(let reason):
      return String(localized: "Ticket resolvers couldn't be saved: \(reason)", bundle: .module)
    }
  }
}

/// Where the ticket resolvers are kept (#89).
public protocol TicketResolverRepository: Sendable {
  /// The stored document; `TicketResolverDocument.shipped` when nothing was ever saved.
  func document() async throws -> TicketResolverDocument
  func save(_ resolvers: [TicketResolver]) async throws
  /// Where the file is, for Reveal in Finder. `nil`: nowhere on disk.
  var fileURL: URL? { get }
}

/// Resolvers held in memory, for tests and for a workspace assembled without a store.
public actor InMemoryTicketResolverRepository: TicketResolverRepository {
  private var stored: TicketResolverDocument

  public init(document: TicketResolverDocument = .shipped) {
    stored = document
  }

  public func document() -> TicketResolverDocument {
    stored
  }

  public func save(_ resolvers: [TicketResolver]) {
    stored = TicketResolverDocument(
      resolvers: resolvers,
      knownPresets: stored.knownPresets.union(TicketResolverPresets.all.compactMap(\.preset?.id)))
  }

  public nonisolated var fileURL: URL? { nil }
}

/// The switch and the line format of the ticket titles (#89).
@MainActor
public protocol TicketTitlePreferences: AnyObject {
  /// On by default: nothing is loaded for an address no resolver recognises anyway.
  var insertsTicketTitles: Bool { get set }
  var lineFormat: TicketLineFormat { get set }
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
@MainActor
public final class InMemoryTicketTitlePreferences: TicketTitlePreferences {
  public var insertsTicketTitles: Bool
  public var lineFormat: TicketLineFormat

  public init(insertsTicketTitles: Bool = true, lineFormat: TicketLineFormat = .standard) {
    self.insertsTicketTitles = insertsTicketTitles
    self.lineFormat = lineFormat
  }
}

// MARK: - Reading a ticket's page

/// What became of a ticket's page, read in the session's web view.
public enum TicketPageOutcome: Hashable, Sendable {
  /// The page is the ticket's, and gave this title. `raw` is the title before the cleanup.
  case title(String, raw: String)
  /// The site sent a sign-in page, or refused without one. Only given when not waiting for it.
  case signInRequired(host: String)
  /// 404 or 410: the ticket does not exist, or is not visible to whoever is signed in.
  case notFound(status: Int)
  case failed(TicketPageFailure)
  /// The tab was closed, taken elsewhere or let go before the page was read.
  case abandoned
}

public enum TicketPageFailure: Hashable, Sendable {
  case http(status: Int)
  case offline
  case unreachable(host: String)
  case untrustedCertificate(host: String)
  /// Anything else, in WebKit's own words.
  case load(reason: String)
  /// The page loaded and never gave a title that names the ticket.
  case noTitle
  /// The page did not load in time.
  case timedOut
}

/// Where a reading that waits for the user stands.
public enum TicketPageProgress: Hashable, Sendable {
  case loading
  /// The page is a sign-in page, or refused: the reading waits for the user to sign in.
  case signInRequired(host: String)
  /// 404 or 410: missing, or private and not visible yet. Waited out like a sign-in.
  case notFound(status: Int)
}

/// Reads the title of a ticket's page in a session's web view.
@MainActor
public protocol TicketPageReading: AnyObject {
  /// Opens the ticket in the session's web view — the tab that already shows it, else a new tab
  /// in the background — and reads its title once the page is the ticket's.
  ///
  /// A sign-in page is waited out, for as long as the tab stays, and said through `progress`.
  func readTicket(
    _ ticket: TicketRecognition,
    resolvers: TicketResolverSet,
    in session: SessionID,
    progress: @escaping @MainActor (TicketPageProgress) -> Void
  ) async -> TicketPageOutcome

  /// Loads an address apart from any session, for the settings' test, and reads it without
  /// waiting for a sign-in.
  func testTicketPage(_ ticket: TicketRecognition, resolvers: TicketResolverSet) async
    -> TicketPageOutcome

  /// Brings the session's tab on this ticket forward, in a web view shown.
  func showTicket(_ ticket: TicketRecognition, resolvers: TicketResolverSet, in session: SessionID)
}

// MARK: - Exchange

/// The file resolvers travel in between two Macs, documented in `docs/ticket-resolvers.md`.
public enum TicketResolverExchange {
  public static let format = "vibe-manager.ticket-resolvers"
  public static let version = 1

  public enum DecodingError: Error, Equatable, Sendable {
    case notAResolverFile
    case unsupportedVersion(Int)
  }

  /// What a file held: the resolvers that can be used, and how many were left out.
  public struct Decoded: Sendable {
    public let resolvers: [TicketResolver]
    public let skipped: Int
  }

  private struct Envelope: Decodable {
    var format: String
    var version: Int
    var exportedAt: String?
    var resolvers: [LenientResolver]
  }

  private struct ExportedEnvelope: Encodable {
    var format: String
    var version: Int
    var exportedAt: String
    var resolvers: [ExportedResolver]
  }

  /// A resolver as a file holds it. The preset origin is not exported: in another library, an
  /// imported resolver is the user's own.
  private struct ExportedResolver: Codable {
    var id: UUID
    var name: String
    var isEnabled: Bool?
    var pattern: String
    var shortID: String
    var titleCleanup: [String]?
  }

  private struct LenientResolver: Decodable {
    let value: ExportedResolver?

    init(from decoder: any Decoder) throws {
      value = try? ExportedResolver(from: decoder)
    }
  }

  public static func encode(_ resolvers: [TicketResolver], exportedAt date: Date) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let envelope = ExportedEnvelope(
      format: format, version: version,
      exportedAt: date.formatted(
        .iso8601.year().month().day().time(includingFractionalSeconds: true)),
      resolvers: resolvers.map {
        ExportedResolver(
          id: $0.id, name: $0.name, isEnabled: $0.isEnabled, pattern: $0.pattern,
          shortID: $0.shortID, titleCleanup: $0.titleCleanup)
      })
    return try encoder.encode(envelope)
  }

  public static func decode(_ data: Data) throws -> Decoded {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      envelope.format == format
    else { throw DecodingError.notAResolverFile }
    guard envelope.version <= version else {
      throw DecodingError.unsupportedVersion(envelope.version)
    }
    var resolvers: [TicketResolver] = []
    var skipped = 0
    for entry in envelope.resolvers {
      guard let exported = entry.value else {
        skipped += 1
        continue
      }
      let resolver = TicketResolver(
        id: exported.id, name: exported.name, isEnabled: exported.isEnabled ?? true,
        pattern: exported.pattern, shortID: exported.shortID,
        titleCleanup: exported.titleCleanup ?? [])
      guard resolver.validate().isEmpty else {
        skipped += 1
        continue
      }
      resolvers.append(resolver)
    }
    return Decoded(resolvers: resolvers, skipped: skipped)
  }

  /// `imported` added to `library`: a known identifier replaces its resolver where it is, a name
  /// already taken is suffixed ` 2`, ` 3`…
  public static func merge(_ imported: [TicketResolver], into library: [TicketResolver])
    -> [TicketResolver]
  {
    var result = library
    for resolver in imported {
      if let index = result.firstIndex(where: { $0.id == resolver.id }) {
        var replacing = resolver
        replacing.preset = nil
        result[index] = replacing
        continue
      }
      var added = resolver
      added.name = uniqueName(resolver.trimmedName, among: result.map(\.trimmedName))
      result.append(added)
    }
    return result
  }

  public static func uniqueName(_ name: String, among names: [String]) -> String {
    let taken = Set(names.map { $0.lowercased() })
    guard taken.contains(name.lowercased()) else { return name }
    var index = 2
    while taken.contains("\(name) \(index)".lowercased()) { index += 1 }
    return "\(name) \(index)"
  }
}
