import Foundation

/// What the library of avatars allows, whatever keeps it (#154).
public enum AvatarLibraryRules {
  /// At most this many avatars besides the default one, drafts included: one weighs 3 to 6 MB,
  /// so about 120 MB at most.
  public static let maximumCount = 20

  /// What the default avatar is called, whatever its manifest says.
  public static var defaultAvatarName: String {
    String(localized: "Default Avatar", bundle: .module)
  }

  /// The default avatar first, then the others in the order they entered the library: the latest,
  /// a draft just made, last.
  public static func ordered(_ entries: [AvatarLibraryEntry]) -> [AvatarLibraryEntry] {
    entries.sorted { lhs, rhs in
      if (lhs.id == .default) != (rhs.id == .default) { return lhs.id == .default }
      if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
      return lhs.id.description < rhs.id.description
    }
  }

  /// A name as the library keeps it: its first line, trimmed, at most
  /// `AvatarManifest.maximumNameLength` characters. `nil` when nothing is left.
  public static func name(_ proposed: String) -> String? {
    let line =
      proposed.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    guard !line.isEmpty else { return nil }
    return String(line.prefix(AvatarManifest.maximumNameLength))
  }

  /// The name of a copy: the original's, followed by "(copy)" in the user's language, shortened so
  /// that the whole fits.
  public static func copyName(of name: String) -> String {
    let suffix = copyName(ofTrimmed: "")
    let room = max(AvatarManifest.maximumNameLength - suffix.count, 0)
    let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = String(original.prefix(room)).trimmingCharacters(in: .whitespaces)
    return copyName(ofTrimmed: base.isEmpty ? "Avatar" : base)
  }

  private static func copyName(ofTrimmed name: String) -> String {
    String(localized: "\(name) (copy)", bundle: .module)
  }

  /// The stored avatar `id` names, which can be changed.
  /// - Throws: `AvatarLibraryError.defaultAvatarIsFixed` for the default one.
  public static func modifiable(_ id: AvatarID) throws -> UUID {
    guard let uuid = id.storedID else { throw AvatarLibraryError.defaultAvatarIsFixed }
    return uuid
  }
}

/// Which avatars the library holds, in which state, and which one is in use: what `library.json`
/// says, without the images (#154). Its changes follow `AvatarLibraryRules`, and refuse without
/// changing anything.
public struct AvatarLibraryIndex: Hashable, Sendable {
  public struct Record: Hashable, Sendable {
    public let id: UUID
    public var state: AvatarLibraryEntry.State
    public var addedAt: Date

    public init(id: UUID, state: AvatarLibraryEntry.State, addedAt: Date) {
      self.id = id
      self.state = state
      self.addedAt = addedAt
    }
  }

  /// What keeping a draft does to the images.
  public enum Keeping: Hashable, Sendable {
    /// The draft becomes a kept avatar where it is.
    case promoted(UUID)
    /// The draft's images replace the original's, which keeps its identifier; the draft is gone.
    case replaced(original: UUID, draft: UUID)

    /// The avatar kept.
    public var kept: UUID {
      switch self {
      case .promoted(let id): return id
      case .replaced(let original, _): return original
      }
    }
  }

  public private(set) var inUse: AvatarID
  public private(set) var records: [Record]

  public init(inUse: AvatarID = .default, records: [Record] = []) {
    self.records = records
    self.inUse = .default
    // An index read from disk may name an avatar it no longer holds, or a draft.
    if let id = inUse.storedID, record(id)?.state == .kept { self.inUse = inUse }
  }

  public func record(_ id: UUID) -> Record? {
    records.first { $0.id == id }
  }

  /// Whether one more avatar fits.
  public var hasRoom: Bool { records.count < AvatarLibraryRules.maximumCount }

  /// Adds an avatar just made, as a draft, or a copy, as kept.
  /// - Throws: `AvatarLibraryError.limitReached`, or `.notFound` when `basedOn` is not a kept
  ///   avatar.
  public mutating func add(_ id: UUID, as state: AvatarLibraryEntry.State, at date: Date) throws {
    guard hasRoom else { throw AvatarLibraryError.limitReached }
    if case .draft(let basedOn?) = state {
      let original = try AvatarLibraryRules.modifiable(basedOn)
      guard self.record(original)?.state == .kept else { throw AvatarLibraryError.notFound }
    }
    records.append(Record(id: id, state: state, addedAt: date))
  }

  /// Keeps a draft, complete: `missing` is what its images lack.
  public mutating func keep(_ id: AvatarID, missing: [AvatarExpression]) throws -> Keeping {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let index = records.firstIndex(where: { $0.id == uuid }) else {
      throw AvatarLibraryError.notFound
    }
    guard case .draft(let basedOn) = records[index].state else {
      throw AvatarLibraryError.notADraft
    }
    guard missing.isEmpty else { throw AvatarLibraryError.incomplete(missing) }
    if let original = basedOn?.storedID, record(original) != nil {
      records.remove(at: index)
      return .replaced(original: original, draft: uuid)
    }
    records[index].state = .kept
    return .promoted(uuid)
  }

  /// Deletes an avatar or discards a draft. The one in use gives its place to the default one;
  /// the drafts based on it become drafts of their own.
  public mutating func remove(_ id: AvatarID) throws {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard records.contains(where: { $0.id == uuid }) else { throw AvatarLibraryError.notFound }
    records.removeAll { $0.id == uuid }
    if inUse == id { inUse = .default }
    for index in records.indices where records[index].state == .draft(basedOn: id) {
      records[index].state = .draft(basedOn: nil)
    }
  }

  /// Uses a kept avatar, or the default one.
  public mutating func setInUse(_ id: AvatarID) throws {
    if let uuid = id.storedID {
      guard let record = record(uuid) else { throw AvatarLibraryError.notFound }
      guard record.state == .kept else { throw AvatarLibraryError.notKept }
    }
    inUse = id
  }

  /// Checks that `id` names a draft, to update it.
  public func draft(_ id: AvatarID) throws -> UUID {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let record = record(uuid) else { throw AvatarLibraryError.notFound }
    guard case .draft = record.state else { throw AvatarLibraryError.notADraft }
    return uuid
  }

  /// Checks that `id` names an avatar of the library, to rename or read it.
  public func contains(_ id: AvatarID) -> Bool {
    guard let uuid = id.storedID else { return true }
    return record(uuid) != nil
  }
}
