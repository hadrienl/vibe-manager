import Foundation

/// A library that stays in memory for the run: what a workspace assembled without disk uses, and
/// what the tests of the screens drive (#154).
public actor InMemoryAvatarLibrary: AvatarLibrary {
  private let defaultAvatar: AvatarSpriteSet?
  private let now: @Sendable () -> Date
  private let makeID: @Sendable () -> UUID
  private var index = AvatarLibraryIndex()
  private var avatars: [UUID: AvatarSpriteSet] = [:]

  /// - Parameters:
  ///   - defaultAvatar: the one shipped with the application; without it, the default entry is
  ///     listed as unreadable.
  ///   - kept: avatars already kept, in this order, as a library read from disk would hold them.
  public init(
    defaultAvatar: AvatarSpriteSet? = nil, kept: [AvatarSpriteSet] = [],
    now: @escaping @Sendable () -> Date = Date.init,
    makeID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.defaultAvatar = defaultAvatar
    self.now = now
    self.makeID = makeID
    var records: [AvatarLibraryIndex.Record] = []
    for avatar in kept {
      let id = makeID()
      records.append(.init(id: id, state: .kept, addedAt: now()))
      avatars[id] = avatar
    }
    index = AvatarLibraryIndex(records: records)
  }

  public func entries() async throws -> [AvatarLibraryEntry] {
    let defaultEntry = AvatarLibraryEntry(
      id: .default, state: .kept, manifest: defaultAvatar?.manifest, addedAt: .distantPast,
      problem: defaultAvatar == nil ? .unreadable : nil)
    let stored = index.records.compactMap { record -> AvatarLibraryEntry? in
      guard let avatar = avatars[record.id] else { return nil }
      let incomplete = record.state == .kept && !avatar.isComplete
      return AvatarLibraryEntry(
        id: .stored(record.id), state: record.state, manifest: avatar.manifest,
        addedAt: record.addedAt, byteCount: Self.byteCount(of: avatar),
        problem: incomplete ? .incomplete(avatar.missingExpressions) : nil)
    }
    return AvatarLibraryRules.ordered([defaultEntry] + stored)
  }

  public func canCreate() async throws -> Bool { index.canCreate }

  public func load(_ id: AvatarID) async throws -> AvatarSpriteSet {
    guard let uuid = id.storedID else {
      guard let defaultAvatar else { throw AvatarStoreError.unreadable }
      return defaultAvatar
    }
    guard let avatar = avatars[uuid] else { throw AvatarLibraryError.notFound }
    return avatar
  }

  public func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID {
    let id = makeID()
    try index.addDraft(id, basedOn: basedOn, at: now())
    avatars[id] = avatar
    return .stored(id)
  }

  public func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws {
    avatars[try index.draft(id)] = avatar
  }

  public func draftToComplete(_ id: AvatarID) async throws -> AvatarID {
    _ = try AvatarLibraryRules.modifiable(id)
    try index.checkKept(id)
    if let existing = index.draft(redrawing: id) { return .stored(existing) }
    return try await saveDraft(try await load(id), basedOn: id)
  }

  public func keep(_ id: AvatarID) async throws -> AvatarID {
    let uuid = try index.draft(id)
    guard let draft = avatars[uuid] else { throw AvatarLibraryError.notFound }
    switch try index.keep(id, missing: draft.missingExpressions) {
    case .promoted(let kept):
      return .stored(kept)
    case .replaced(let original, let draftID):
      if let kept = avatars[original] {
        avatars[original] = AvatarLibraryRules.replacing(kept, with: draft)
      }
      avatars[draftID] = nil
      return .stored(original)
    }
  }

  public func rename(_ id: AvatarID, to name: String) async throws {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let kept = AvatarLibraryRules.name(name) else { throw AvatarLibraryError.emptyName }
    guard index.contains(id), avatars[uuid] != nil else { throw AvatarLibraryError.notFound }
    avatars[uuid]?.manifest.name = kept
  }

  public func duplicate(_ id: AvatarID) async throws -> AvatarID {
    try index.checkKept(id)
    var copy = try await load(id)
    guard copy.isComplete else { throw AvatarLibraryError.incomplete(copy.missingExpressions) }
    copy.manifest.name = AvatarLibraryRules.copyName(
      of: id == .default ? AvatarLibraryRules.defaultAvatarName : copy.manifest.name)
    copy.manifest.source = .imported
    copy.manifest.createdAt = now()
    let uuid = makeID()
    try index.addCopy(uuid, at: now())
    avatars[uuid] = copy
    return .stored(uuid)
  }

  public func remove(_ id: AvatarID) async throws {
    try index.remove(id)
    if let uuid = id.storedID { avatars[uuid] = nil }
  }

  public func inUse() async throws -> AvatarID { index.inUse }

  public func setInUse(_ id: AvatarID) async throws {
    try index.checkKept(id)
    if let uuid = id.storedID, let avatar = avatars[uuid], !avatar.isComplete {
      throw AvatarLibraryError.incomplete(avatar.missingExpressions)
    }
    try index.setInUse(id)
  }

  static func byteCount(of avatar: AvatarSpriteSet) -> Int64 {
    Int64(avatar.sprites.values.reduce(0) { $0 + $1.count } + (avatar.sheet?.count ?? 0))
  }
}
