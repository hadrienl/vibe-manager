import Foundation

/// What the library of avatars allows, whatever keeps it (#154).
public enum AvatarLibraryRules {
  /// At most this many avatars besides the default one, drafts included — but not those that
  /// redraw a kept avatar, which replace it. One weighs 3 to 6 MB, so about 120 MB at most.
  ///
  /// The limit stops new creations — a generation, an import, a copy — before they start. What a
  /// generation or an import brings back is always written, even beyond it: what was made is never
  /// lost.
  public static let maximumCount = 20

  /// What the default avatar is called, whatever its manifest says.
  public static var defaultAvatarName: String {
    String(
      localized: "Default Avatar", bundle: .module,
      comment: "The avatar shipped with the application, in the list of avatars.")
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

  /// A name as the library keeps it: its first line that is not blank, trimmed, at most
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
    let suffix = copyName(ofCleaned: "")
    let room = max(AvatarManifest.maximumNameLength - suffix.count, 1)
    let base = Self.name(Self.name(name).map { String($0.prefix(room)) } ?? "")
    return copyName(
      ofCleaned: base
        ?? String(
          localized: "Avatar", bundle: .module,
          comment: "The name of a copy of an avatar that had none."))
  }

  private static func copyName(ofCleaned name: String) -> String {
    String(
      localized: "\(name) (copy)", bundle: .module,
      comment: "The name of a copy of an avatar; %@ is the original's name.")
  }

  /// The stored avatar `id` names, which can be changed.
  /// - Throws: `AvatarLibraryError.defaultAvatarIsFixed` for the default one.
  public static func modifiable(_ id: AvatarID) throws -> UUID {
    guard let uuid = id.storedID else { throw AvatarLibraryError.defaultAvatarIsFixed }
    return uuid
  }

  /// What a kept avatar becomes when the draft that redraws it is kept: the draft's images and
  /// the description they were drawn from, under the original's name.
  public static func replacing(_ original: AvatarSpriteSet, with draft: AvatarSpriteSet)
    -> AvatarSpriteSet
  {
    var result = draft
    result.manifest = original.manifest
    result.manifest.description = draft.manifest.description
    result.manifest.expressions = draft.manifest.expressions
    return result
  }
}

/// Which avatars the library holds, in which state, and which one is in use: `library.json`,
/// without the images (#154). Its changes follow `AvatarLibraryRules`, and refuse without changing
/// anything.
///
/// ```json
/// { "format": 1, "inUse": "<id>|default",
///   "entries": [ { "id": "<id>", "state": "kept|draft", "basedOn": "<id>",
///                  "addedAt": "2026-09-28T10:00:00.000Z" } ] }
/// ```
public struct AvatarLibraryIndex: Hashable, Sendable, Codable {
  /// The version of `library.json` this application writes. One of a later version is not read:
  /// the index is rebuilt from the folders.
  public static let currentFormat = 1

  public struct Record: Hashable, Sendable, Codable {
    public let id: UUID
    public var state: AvatarLibraryEntry.State
    public var addedAt: Date

    public init(id: UUID, state: AvatarLibraryEntry.State, addedAt: Date) {
      self.id = id
      self.state = state
      self.addedAt = addedAt
    }

    /// A draft that redraws another avatar: it does not count in the limit.
    var redraws: Bool {
      if case .draft(basedOn: .some) = state { return true }
      return false
    }

    enum CodingKeys: String, CodingKey {
      case id, state, basedOn, addedAt
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(UUID.self, forKey: .id)
      switch try container.decode(String.self, forKey: .state) {
      case "kept":
        state = .kept
      case "draft":
        state = .draft(basedOn: try? container.decodeIfPresent(AvatarID.self, forKey: .basedOn))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .state, in: container, debugDescription: "Not an avatar state.")
      }
      let date = try? container.decodeIfPresent(String.self, forKey: .addedAt)
      addedAt = date.flatMap { try? Date($0, strategy: Self.dateStyle) } ?? .distantPast
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      switch state {
      case .kept:
        try container.encode("kept", forKey: .state)
      case .draft(let basedOn):
        try container.encode("draft", forKey: .state)
        try container.encodeIfPresent(basedOn, forKey: .basedOn)
      }
      try container.encode(addedAt.formatted(Self.dateStyle), forKey: .addedAt)
    }

    /// To the millisecond: two avatars added in the same second keep their order.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  }

  /// What keeping a draft does to the images.
  public enum Keeping: Hashable, Sendable {
    /// The draft becomes a kept avatar where it is.
    case promoted(UUID)
    /// The draft's images replace the original's, which keeps its identifier, its name, its place
    /// and its use (`AvatarLibraryRules.replacing`); the draft is gone.
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

  /// An index as read from disk is made consistent: each avatar once, a draft based only on a kept
  /// avatar, the one in use kept.
  public init(inUse: AvatarID = .default, records: [Record] = []) {
    var seen = Set<UUID>()
    let unique = records.filter { seen.insert($0.id).inserted }
    let kept = Set(unique.filter { $0.state == .kept }.map(\.id))
    self.records = unique.map { record in
      var record = record
      if case .draft(let basedOn?) = record.state,
        basedOn.storedID.map({ !kept.contains($0) || $0 == record.id }) ?? true
      {
        record.state = .draft(basedOn: nil)
      }
      return record
    }
    self.inUse = inUse.storedID.map { kept.contains($0) } == true ? inUse : .default
  }

  enum CodingKeys: String, CodingKey {
    case format, inUse, entries
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let format = try container.decode(Int.self, forKey: .format)
    guard format <= Self.currentFormat else {
      throw DecodingError.dataCorruptedError(
        forKey: .format, in: container, debugDescription: "A later version's library.")
    }
    self.init(
      inUse: (try? container.decodeIfPresent(AvatarID.self, forKey: .inUse)) ?? .default,
      records: try container.decode([Record].self, forKey: .entries))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentFormat, forKey: .format)
    try container.encode(inUse, forKey: .inUse)
    try container.encode(records, forKey: .entries)
  }

  public func record(_ id: UUID) -> Record? {
    records.first { $0.id == id }
  }

  /// Whether a new avatar can be made — generated, imported or copied: fewer than
  /// `AvatarLibraryRules.maximumCount`, not counting the drafts that redraw a kept avatar.
  public var canCreate: Bool {
    records.filter { !$0.redraws }.count < AvatarLibraryRules.maximumCount
  }

  /// Adds what a generation, an import or a redrawing brought back, as a draft: always, even beyond
  /// the limit, so that it is not lost.
  /// - Throws: `.notFound` when `basedOn` is not a kept avatar.
  public mutating func addDraft(_ id: UUID, basedOn: AvatarID?, at date: Date) throws {
    if let basedOn {
      let original = try AvatarLibraryRules.modifiable(basedOn)
      guard self.record(original)?.state == .kept else { throw AvatarLibraryError.notFound }
    }
    records.append(Record(id: id, state: .draft(basedOn: basedOn), addedAt: date))
  }

  /// Adds a copy, kept.
  /// - Throws: `AvatarLibraryError.limitReached` when no new avatar can be made.
  public mutating func addCopy(_ id: UUID, at date: Date) throws {
    guard canCreate else { throw AvatarLibraryError.limitReached }
    records.append(Record(id: id, state: .kept, addedAt: date))
  }

  /// Keeps a draft, complete: `missing` is what its images lack.
  public mutating func keep(_ id: AvatarID, missing: [AvatarExpression]) throws -> Keeping {
    let uuid = try draft(id)
    guard missing.isEmpty else { throw AvatarLibraryError.incomplete(missing) }
    guard let index = records.firstIndex(where: { $0.id == uuid }) else {
      throw AvatarLibraryError.notFound
    }
    if case .draft(let basedOn?) = records[index].state, let original = basedOn.storedID,
      record(original)?.state == .kept
    {
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
    try checkKept(id)
    inUse = id
  }

  /// Checks that `id` names the default avatar or a kept one.
  public func checkKept(_ id: AvatarID) throws {
    guard let uuid = id.storedID else { return }
    guard let record = record(uuid) else { throw AvatarLibraryError.notFound }
    guard record.state == .kept else { throw AvatarLibraryError.notKept }
  }

  /// Checks that `id` names a draft, to update or keep it.
  public func draft(_ id: AvatarID) throws -> UUID {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let record = record(uuid) else { throw AvatarLibraryError.notFound }
    guard case .draft = record.state else { throw AvatarLibraryError.notADraft }
    return uuid
  }

  /// The draft that redraws `id`, if one does.
  public func draft(redrawing id: AvatarID) -> UUID? {
    records.first { $0.state == .draft(basedOn: id) }?.id
  }

  /// Whether `id` names an avatar of the library.
  public func contains(_ id: AvatarID) -> Bool {
    guard let uuid = id.storedID else { return true }
    return record(uuid) != nil
  }
}
