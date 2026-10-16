import Foundation

/// A sound of the user's own (#393): imported from a file, or composed by an agent.
public struct AlertSoundID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString }
}

/// The sound played when a session out of sight needs the user (#393): a request arrived, or it
/// replied, failed or stopped.
public enum AlertSoundChoice: Hashable, Sendable {
  /// The alert sound chosen in System Settings: what the notifications played before #393.
  case systemDefault
  /// The notification stays, without a sound.
  case none
  /// One shipped with the application, by its key in `BundledAlertSound`.
  case bundled(String)
  /// One of `/System/Library/Sounds`, by its file name without extension.
  case macOS(String)
  /// One of the user's own sounds.
  case custom(AlertSoundID)

  /// What the user defaults keep: `default`, `none`, `bundled:chime`, `system:Glass`,
  /// `custom:<uuid>`.
  public var rawValue: String {
    switch self {
    case .systemDefault: "default"
    case .none: "none"
    case .bundled(let key): "bundled:\(key)"
    case .macOS(let name): "system:\(name)"
    case .custom(let id): "custom:\(id.rawValue.uuidString)"
    }
  }

  /// What `rawValue` wrote; anything else — written by a later version, or damaged — is `nil`, and
  /// reads as the system's default.
  public init?(rawValue: String) {
    switch rawValue {
    case "default": self = .systemDefault
    case "none": self = .none
    default:
      guard let colon = rawValue.firstIndex(of: ":") else { return nil }
      let value = String(rawValue[rawValue.index(after: colon)...])
      guard !value.isEmpty else { return nil }
      switch rawValue[..<colon] {
      case "bundled": self = .bundled(value)
      case "system": self = .macOS(value)
      case "custom":
        guard let uuid = UUID(uuidString: value) else { return nil }
        self = .custom(AlertSoundID(rawValue: uuid))
      default: return nil
      }
    }
  }
}

/// Where a sound of the user's own comes from.
public enum AlertSoundOrigin: Hashable, Sendable, Codable {
  /// Read from an audio file.
  case imported
  /// Composed by an agent, by its provider's identifier.
  case composed(agent: String)
}

/// A sound of the user's own, as the library lists it.
public struct AlertSoundEntry: Identifiable, Hashable, Sendable, Codable {
  public let id: AlertSoundID
  public var name: String
  public var origin: AlertSoundOrigin
  /// When it entered the library: its place in the list.
  public var addedAt: Date
  /// How long it plays, in seconds.
  public var duration: Double
  /// What it takes on disk.
  public var byteCount: Int64
  /// For a sound composed by an agent: what it plays, which a change starts from.
  public var recipe: AlertSoundRecipe?
  /// For a sound composed by an agent: what the user asked, oldest first — its description, then
  /// each change.
  public var requests: [String]

  public init(
    id: AlertSoundID = AlertSoundID(), name: String, origin: AlertSoundOrigin, addedAt: Date,
    duration: Double, byteCount: Int64 = 0, recipe: AlertSoundRecipe? = nil,
    requests: [String] = []
  ) {
    self.id = id
    self.name = name
    self.origin = origin
    self.addedAt = addedAt
    self.duration = duration
    self.byteCount = byteCount
    self.recipe = recipe
    self.requests = requests
  }

  /// What the user first described, for a composed sound.
  public var description: String? { requests.first }
}

/// Why the library refused a change. Nothing was changed.
public enum AlertSoundLibraryError: Error, Hashable, Sendable {
  case notFound
  /// `AlertSoundRules.maximumCount` sounds already.
  case limitReached
  /// A name is not only blank.
  case emptyName
  /// The library could not be read or written.
  case storage
}

/// The sounds of the user's own (#393). Every change is whole or not at all.
public protocol AlertSoundLibrary: Sendable {
  /// Every sound, in the order they entered the library.
  func entries() async throws -> [AlertSoundEntry]
  /// The file of a sound: a WAV, 16-bit PCM.
  func fileURL(of id: AlertSoundID) async throws -> URL
  /// Adds a sound; `wave` is a WAV file as `AlertSoundWave.encode` writes one.
  func add(_ entry: AlertSoundEntry, wave: Data) async throws -> AlertSoundEntry
  /// Replaces what a composed sound plays: a change of it, or one of its earlier versions.
  func replace(_ id: AlertSoundID, with entry: AlertSoundEntry, wave: Data) async throws
    -> AlertSoundEntry
  func rename(_ id: AlertSoundID, to name: String) async throws
  func remove(_ id: AlertSoundID) async throws
}

/// What the library holds, and the names it gives.
public enum AlertSoundRules {
  /// A list a user can still look through.
  public static let maximumCount = 50
  public static let maximumNameLength = 60
  /// The longest a notification of macOS plays.
  public static let maximumImportedDuration: Double = 30

  /// A name as the library keeps it: one line, trimmed, `maximumNameLength` characters at most.
  /// `nil` when nothing is left.
  public static func name(_ proposed: String) -> String? {
    let line = proposed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maximumNameLength))
  }
}

/// Where the choice of the alert sound is kept.
@MainActor
public protocol AlertSoundPreferences: AnyObject {
  var alertSound: AlertSoundChoice { get set }
}

/// Kept for this run only.
@MainActor
public final class InMemoryAlertSoundPreferences: AlertSoundPreferences {
  public var alertSound: AlertSoundChoice

  public init(alertSound: AlertSoundChoice = .systemDefault) {
    self.alertSound = alertSound
  }
}

/// The library in memory: what a workspace assembled without the disk uses, and the tests.
public actor InMemoryAlertSoundLibrary: AlertSoundLibrary {
  private var stored: [AlertSoundEntry] = []
  private var waves: [AlertSoundID: Data] = [:]
  private let folder: URL

  /// - Parameter folder: where `fileURL(of:)` writes a sound when asked for its file.
  public init(folder: URL = FileManager.default.temporaryDirectory) {
    self.folder = folder
  }

  public func entries() async throws -> [AlertSoundEntry] { stored }

  public func fileURL(of id: AlertSoundID) async throws -> URL {
    guard let wave = waves[id] else { throw AlertSoundLibraryError.notFound }
    let url = folder.appendingPathComponent("\(id.rawValue.uuidString).wav")
    do {
      try wave.write(to: url)
    } catch {
      throw AlertSoundLibraryError.storage
    }
    return url
  }

  public func add(_ entry: AlertSoundEntry, wave: Data) async throws -> AlertSoundEntry {
    guard stored.count < AlertSoundRules.maximumCount else {
      throw AlertSoundLibraryError.limitReached
    }
    guard let name = AlertSoundRules.name(entry.name) else {
      throw AlertSoundLibraryError.emptyName
    }
    var entry = entry
    entry.name = name
    entry.byteCount = Int64(wave.count)
    stored.append(entry)
    waves[entry.id] = wave
    return entry
  }

  public func replace(_ id: AlertSoundID, with entry: AlertSoundEntry, wave: Data) async throws
    -> AlertSoundEntry
  {
    guard let index = stored.firstIndex(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    var entry = entry
    entry.byteCount = Int64(wave.count)
    // Its identifier, its name and its place stay.
    entry = AlertSoundEntry(
      id: id, name: stored[index].name, origin: entry.origin, addedAt: stored[index].addedAt,
      duration: entry.duration, byteCount: entry.byteCount, recipe: entry.recipe,
      requests: entry.requests)
    stored[index] = entry
    waves[id] = wave
    return entry
  }

  public func rename(_ id: AlertSoundID, to name: String) async throws {
    guard let index = stored.firstIndex(where: { $0.id == id }) else {
      throw AlertSoundLibraryError.notFound
    }
    guard let name = AlertSoundRules.name(name) else { throw AlertSoundLibraryError.emptyName }
    stored[index].name = name
  }

  public func remove(_ id: AlertSoundID) async throws {
    guard stored.contains(where: { $0.id == id }) else { throw AlertSoundLibraryError.notFound }
    stored.removeAll { $0.id == id }
    waves[id] = nil
  }
}

/// Puts the sound in use where the notifications of macOS find it (#393): they play only a sound
/// of the application's bundle or of `~/Library/Sounds`.
public protocol NotificationSoundInstalling: Sendable {
  /// Copies `source` there under a name of the application's, in place of the one copied before,
  /// and returns the file name a notification plays.
  func install(_ source: URL, name: String) throws -> String
  /// Removes what was copied: the sound in use is the system's, or none.
  func clear()
}
