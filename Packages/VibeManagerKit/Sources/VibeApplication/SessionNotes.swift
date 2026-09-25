import Foundation
import VibeDomain

/// What the user wrote about a session, as it was last written to disk.
public struct SessionNotes: Hashable, Sendable {
  public let text: String
  /// When the notes were last written. `nil`: they never were.
  public let modifiedAt: Date?

  public init(text: String, modifiedAt: Date?) {
    self.text = text
    self.modifiedAt = modifiedAt
  }

  public static let empty = SessionNotes(text: "", modifiedAt: nil)
}

public enum SessionNotesLimits {
  /// The most a session's notes may weigh, in UTF-8 bytes.
  ///
  /// About thirty pages: far above a note, below a log pasted by mistake. Every session's notes
  /// are held in memory for the search, and this is what bounds that memory.
  public static let byteLimit = 64 * 1024
  /// From here on the editor says how close the notes are to the limit.
  public static let warningByteCount = 56 * 1024

  /// Whether `text` may replace notes that weigh `current` bytes.
  ///
  /// Anything under the limit may. Over it, only a text that shrinks: a file written by hand, or
  /// by a future version, must stay editable down to size rather than become frozen.
  public static func accepts(_ text: String, replacing current: Int) -> Bool {
    let count = text.utf8.count
    return count <= byteLimit || count <= current
  }
}

public enum SessionNotesError: Error, Equatable, Sendable, LocalizedError {
  /// Writing would take the notes over `SessionNotesLimits.byteLimit`.
  case tooLarge(byteCount: Int, limit: Int)
  /// The file is there but could not be read — invalid UTF-8, a permission. It is never
  /// overwritten: the bytes that could not be read are the only copy of what was written.
  case unreadable(reason: String)
  /// The file could not be written — a full disk, a folder that went away.
  case cannotWrite(reason: String)

  public var errorDescription: String? {
    switch self {
    case .tooLarge(let byteCount, let limit):
      return String(
        localized:
          "The notes would weigh \(Self.size(byteCount)); they are limited to \(Self.size(limit)).",
        bundle: .module, comment: "Two sizes, formatted: “70 KB”, “64 KB”.")
    case .unreadable(let reason):
      return String(localized: "The notes could not be read: \(reason)", bundle: .module)
    case .cannotWrite(let reason):
      return String(localized: "The notes could not be saved: \(reason)", bundle: .module)
    }
  }

  /// "64 KB", "1.2 MB", counted in powers of two like the limit itself: counted in thousands,
  /// the limit would read "66 KB" next to a promise of 64.
  public static func size(_ byteCount: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .memory)
  }
}

/// Where the notes of each session are kept, apart from the sessions themselves.
///
/// Apart on purpose: notes are saved while the user types, and a save must neither rewrite the
/// whole session store nor wait behind a close or an archive in its queue.
public protocol SessionNotesStore: Sendable {
  /// The notes of a session; `SessionNotes.empty` when it has none.
  func notes(for id: SessionID) async throws -> SessionNotes
  /// Writes `text` in place of the session's notes, or removes them when it is empty.
  ///
  /// Refused with `tooLarge` past the limit — unless it shrinks notes that were already over it —
  /// and with `unreadable` over a file that could not be read.
  @discardableResult
  func save(_ text: String, for id: SessionID) async throws -> SessionNotes
  /// Every session's notes that can be read, for the search. The others are left out.
  func allNotes() async -> [SessionID: String]
  /// Writes notes found in an older store, unless the session already has some.
  ///
  /// Not held to the limit: those notes were written before there was one, and refusing them
  /// would leave them where nothing shows them any more.
  func importNotes(_ text: String, for id: SessionID) async throws
}

extension SessionNotesStore {
  /// The notes to hand an agent in a summary, or `nil` when there are none or they cannot be read.
  ///
  /// A summary is written with what can be found: notes that fail to load must not stop a restart.
  public func briefNotes(for id: SessionID) async -> String? {
    guard let text = try? await notes(for: id).text else { return nil }
    return text.isEmpty ? nil : text
  }
}

/// Moves the notes a store held inside its sessions into their own store, once.
///
/// The file is written first, and the field cleared only afterwards. Interrupted between the two,
/// the next launch finds the file and clears the field without rewriting it: at no point does the
/// text exist nowhere.
public struct ImportLegacyNotes: Sendable {
  private let repository: any SessionRepository
  private let notes: any SessionNotesStore

  public init(repository: any SessionRepository, notes: any SessionNotesStore) {
    self.repository = repository
    self.notes = notes
  }

  /// - Returns: the sessions whose notes were imported, or found already imported and cleared.
  @discardableResult
  public func callAsFunction() async -> [SessionID] {
    guard let sessions = try? await repository.sessions() else { return [] }
    var cleared: [SessionID] = []
    for session in sessions {
      guard let legacy = session.legacyNotes else { continue }
      if !legacy.isEmpty {
        do {
          try await notes.importNotes(legacy, for: session.id)
        } catch {
          // Left in the session, where it still is: the next launch tries again.
          continue
        }
      }
      do {
        _ = try await repository.mutate(id: session.id) { $0.legacyNotes = nil }
        cleared.append(session.id)
      } catch {
        continue
      }
    }
    return cleared
  }
}

/// A store that keeps nothing, for a workspace assembled without one.
public struct NoSessionNotes: SessionNotesStore {
  public init() {}
  public func notes(for id: SessionID) async throws -> SessionNotes { .empty }
  public func save(_ text: String, for id: SessionID) async throws -> SessionNotes {
    SessionNotes(text: text, modifiedAt: nil)
  }
  public func allNotes() async -> [SessionID: String] { [:] }
  /// Refused, so that the notes stay in the session rather than being cleared into nowhere.
  public func importNotes(_ text: String, for id: SessionID) async throws {
    throw SessionNotesError.cannotWrite(
      reason: String(localized: "there is nowhere to keep notes.", bundle: .module))
  }
}

/// Notes kept in memory, for tests and previews.
public actor InMemorySessionNotesStore: SessionNotesStore {
  private var storage: [SessionID: SessionNotes]
  private var failure: SessionNotesError?
  private var unreadable: Set<SessionID> = []
  public private(set) var saveCount = 0

  public init(notes: [SessionID: String] = [:]) {
    storage = notes.mapValues { SessionNotes(text: $0, modifiedAt: nil) }
  }

  /// Every write fails with `failure` until it is set back to `nil`.
  public func failWrites(with failure: SessionNotesError?) {
    self.failure = failure
  }

  public func markUnreadable(_ id: SessionID) {
    unreadable.insert(id)
  }

  public func notes(for id: SessionID) throws -> SessionNotes {
    if unreadable.contains(id) { throw SessionNotesError.unreadable(reason: "test") }
    return storage[id] ?? .empty
  }

  @discardableResult
  public func save(_ text: String, for id: SessionID) throws -> SessionNotes {
    if unreadable.contains(id) { throw SessionNotesError.unreadable(reason: "test") }
    let current = storage[id]?.text.utf8.count ?? 0
    guard SessionNotesLimits.accepts(text, replacing: current) else {
      throw SessionNotesError.tooLarge(
        byteCount: text.utf8.count, limit: SessionNotesLimits.byteLimit)
    }
    if let failure { throw failure }
    saveCount += 1
    let notes = text.isEmpty ? SessionNotes.empty : SessionNotes(text: text, modifiedAt: Date())
    storage[id] = text.isEmpty ? nil : notes
    return notes
  }

  public func importNotes(_ text: String, for id: SessionID) throws {
    if let failure { throw failure }
    guard storage[id]?.text.isEmpty ?? true else { return }
    storage[id] = SessionNotes(text: text, modifiedAt: Date())
  }

  public func allNotes() -> [SessionID: String] {
    storage.filter { !unreadable.contains($0.key) }.mapValues(\.text)
  }
}
