import Foundation
import VibeApplication

/// The sounds of the user's own on disk (#393), in `Sounds/` beside the session store:
///
/// ```
/// Sounds/
///   library.json      the index: each sound, its name, where it comes from, its recipe
///   <uuid>.wav        the sound, 16-bit PCM
/// ```
///
/// The folder is `0700`, the files `0600`. A sound's file is written before the index names it,
/// and the index is replaced in one step: an interruption leaves at worst a file no index names.
/// Only a sound deleted takes its file away: an index that cannot be read is set aside, never
/// written over, and the sounds it named stay on disk beside it. One written by a later version
/// is left where it is: read as empty, and never written to, so that the later version finds it.
public actor FileAlertSoundLibrary: AlertSoundLibrary {
  static let indexFileName = "library.json"

  private let directory: URL
  private let fileManager = FileManager.default

  public init(directory: URL) {
    self.directory = directory
  }

  private struct Index: Codable {
    static let version = 1
    var version = Self.version
    var sounds: [AlertSoundEntry]
  }

  /// What any version of the index starts with.
  private struct Header: Decodable {
    var version: Int
  }

  private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

  private func waveURL(_ id: AlertSoundID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).wav")
  }

  public func entries() async throws -> [AlertSoundEntry] {
    try readIndex(toWrite: false).sounds
  }

  public func fileURL(of id: AlertSoundID) async throws -> URL {
    guard try readIndex(toWrite: false).sounds.contains(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    let url = waveURL(id)
    guard fileManager.fileExists(atPath: url.path) else { throw AlertSoundLibraryError.notFound }
    return url
  }

  public func add(_ entry: AlertSoundEntry, wave: Data) async throws -> AlertSoundEntry {
    var index = try readIndex()
    guard index.sounds.count < AlertSoundRules.maximumCount else {
      throw AlertSoundLibraryError.limitReached
    }
    guard let name = AlertSoundRules.name(entry.name) else {
      throw AlertSoundLibraryError.emptyName
    }
    var entry = entry
    entry.name = name
    entry.byteCount = Int64(wave.count)
    try prepareDirectory()
    try write(wave, to: waveURL(entry.id))
    index.sounds.append(entry)
    try writeIndex(index)
    return entry
  }

  public func replace(_ id: AlertSoundID, with entry: AlertSoundEntry, wave: Data) async throws
    -> AlertSoundEntry
  {
    var index = try readIndex()
    guard let position = index.sounds.firstIndex(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    let kept = index.sounds[position]
    let replaced = AlertSoundEntry(
      id: id, name: kept.name, origin: entry.origin, addedAt: kept.addedAt,
      duration: entry.duration, byteCount: Int64(wave.count), recipe: entry.recipe,
      requests: entry.requests)
    try write(wave, to: waveURL(id))
    index.sounds[position] = replaced
    try writeIndex(index)
    return replaced
  }

  public func rename(_ id: AlertSoundID, to name: String) async throws {
    var index = try readIndex()
    guard let position = index.sounds.firstIndex(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    guard let name = AlertSoundRules.name(name) else { throw AlertSoundLibraryError.emptyName }
    index.sounds[position].name = name
    try writeIndex(index)
  }

  public func remove(_ id: AlertSoundID) async throws {
    var index = try readIndex()
    guard index.sounds.contains(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    index.sounds.removeAll { $0.id == id }
    try writeIndex(index)
    try? fileManager.removeItem(at: waveURL(id))
  }

  // MARK: - Disk

  /// - Parameter toWrite: whether a change follows, refused on the index of a later version.
  private func readIndex(toWrite: Bool = true) throws -> Index {
    guard fileManager.fileExists(atPath: indexURL.path) else { return Index(sounds: []) }
    // There, and not read now: nothing is written over it.
    guard let data = try? Data(contentsOf: indexURL) else { throw AlertSoundLibraryError.storage }
    if let header = try? Self.decoder.decode(Header.self, from: data),
      header.version > Index.version
    {
      // A later version's: left in place for it, and read as empty.
      if toWrite { throw AlertSoundLibraryError.storage }
      return Index(sounds: [])
    }
    if let index = try? Self.decoder.decode(Index.self, from: data), index.version == Index.version
    {
      return index
    }
    // Damaged: set aside, never written over.
    let aside = directory.appendingPathComponent(
      "library.unreadable-\(Int(Date().timeIntervalSince1970)).json")
    do {
      try fileManager.moveItem(at: indexURL, to: aside)
    } catch {
      throw AlertSoundLibraryError.storage
    }
    return Index(sounds: [])
  }

  private func writeIndex(_ index: Index) throws {
    try prepareDirectory()
    guard let data = try? Self.encoder.encode(index) else { throw AlertSoundLibraryError.storage }
    try write(data, to: indexURL)
    removeLeftovers()
  }

  /// The temporary files of a write that was interrupted.
  private func removeLeftovers() {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp") {
      try? fileManager.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private func prepareDirectory() throws {
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw AlertSoundLibraryError.storage
    }
  }

  /// Written beside, then put in place in one step.
  private func write(_ data: Data, to url: URL) throws {
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      if fileManager.fileExists(atPath: url.path) {
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: url)
      }
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw AlertSoundLibraryError.storage
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// The choice of the alert sound, kept across launches. A key never written, or a value written by
/// a later version, reads as the system's default.
@MainActor
public final class UserDefaultsAlertSoundPreferences: AlertSoundPreferences {
  static let key = "requests.alertSound.v1"
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public var alertSound: AlertSoundChoice {
    get {
      defaults.string(forKey: Self.key).flatMap(AlertSoundChoice.init(rawValue:)) ?? .systemDefault
    }
    set { defaults.set(newValue.rawValue, forKey: Self.key) }
  }
}
