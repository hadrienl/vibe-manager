import Foundation

/// An avatar of the library (#154): the one shipped with the application, or one the user kept.
///
/// The default one is never written anywhere: it cannot be renamed or deleted, only used, exported
/// and duplicated.
public enum AvatarID: Hashable, Sendable, Codable, LosslessStringConvertible {
  case `default`
  case stored(UUID)

  public static let defaultRawValue = "default"

  /// `default`, or the identifier of a stored avatar: what `library.json` and the folders say.
  public init?(_ description: String) {
    if description == Self.defaultRawValue {
      self = .default
    } else if let uuid = UUID(uuidString: description) {
      self = .stored(uuid)
    } else {
      return nil
    }
  }

  public var description: String {
    switch self {
    case .default: return Self.defaultRawValue
    case .stored(let uuid): return uuid.uuidString
    }
  }

  /// The stored avatar's identifier; `nil` for the default one.
  public var storedID: UUID? {
    guard case .stored(let uuid) = self else { return nil }
    return uuid
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let id = AvatarID(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Not an avatar identifier.")
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// An avatar as the library lists it, without its images.
public struct AvatarLibraryEntry: Identifiable, Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// Kept by the user: it can be used.
    case kept
    /// Made and not yet kept: generated, imported, or an expression of `basedOn` drawn again.
    /// Kept, a draft based on another avatar replaces it.
    case draft(basedOn: AvatarID?)
  }

  public let id: AvatarID
  public var state: State
  /// What its manifest says; `nil` when it cannot be read.
  public var manifest: AvatarManifest?
  /// When it entered the library: its place in the list.
  public var addedAt: Date
  /// What it takes on disk.
  public var byteCount: Int64
  /// Why it cannot be used, when it cannot. It stays listed: only the user deletes it.
  public var problem: AvatarStoreError?

  public init(
    id: AvatarID, state: State, manifest: AvatarManifest?, addedAt: Date, byteCount: Int64 = 0,
    problem: AvatarStoreError? = nil
  ) {
    self.id = id
    self.state = state
    self.manifest = manifest
    self.addedAt = addedAt
    self.byteCount = byteCount
    self.problem = problem
  }

  public var isDraft: Bool {
    if case .draft = state { return true }
    return false
  }
}

/// Why the library refused a change. Nothing was changed.
public enum AvatarLibraryError: Error, Hashable, Sendable {
  /// No such avatar in the library: deleted meanwhile.
  case notFound
  /// The default avatar is not written anywhere: it is not renamed, deleted or replaced.
  case defaultAvatarIsFixed
  /// `AvatarLibraryRules.maximumCount` avatars already, drafts included.
  case limitReached
  /// A draft is kept, or discarded, before it is used.
  case notKept
  /// Only a draft is kept, updated or discarded as one.
  case notADraft
  /// A draft is kept only complete.
  case incomplete([AvatarExpression])
  /// A name is not only blank.
  case emptyName
}

/// The avatars the user keeps, the drafts not yet kept, and which one the floating panel shows
/// (#154). The library is the only truth: an avatar deleted cannot stay in use.
///
/// Every change is whole or not at all: a failure leaves the library as it was.
public protocol AvatarLibrary: Sendable {
  /// Every avatar, the default one first, then in the order they entered the library.
  func entries() async throws -> [AvatarLibraryEntry]
  /// An avatar's images.
  /// - Throws: `AvatarLibraryError.notFound`, or the `AvatarStoreError` of one that cannot be read.
  func load(_ id: AvatarID) async throws -> AvatarSpriteSet
  /// Writes what was just made as a draft, at once, so that it outlives the application. `basedOn`
  /// is the kept avatar it redraws, which it replaces once kept.
  func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID
  /// Replaces a draft's images: an expression of a draft drawn again.
  func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws
  /// Keeps a complete draft. One based on a kept avatar replaces it, which keeps its identifier
  /// — and so stays in use if it was. Returns the identifier of the avatar kept.
  func keep(_ id: AvatarID) async throws -> AvatarID
  func rename(_ id: AvatarID, to name: String) async throws
  /// A kept copy, named after the original.
  func duplicate(_ id: AvatarID) async throws -> AvatarID
  /// Deletes an avatar, or discards a draft. The one in use gives its place to the default one.
  func remove(_ id: AvatarID) async throws
  /// The avatar the floating panel shows.
  func inUse() async throws -> AvatarID
  func setInUse(_ id: AvatarID) async throws
}
