import Foundation
import VibeApplication

/// The library of avatars on disk (#154), in `Avatars/` beside the session store:
///
/// ```
/// Avatars/
///   library.json          the index: which avatars, in which state, which one is in use
///   <uuid>/manifest.json  the same manifest as an archive's
///   <uuid>/neutral.png …  the sprites, 512 × 512
///   <uuid>/sheet.png      the sheet they were cut from, when there is one
/// ```
///
/// Folders are `0700`, files `0600`. An avatar is written in a staging folder, then moved in with
/// a single rename; `library.json` is rewritten after it, atomically. A failure halfway undoes what
/// was done: every change is whole or not at all.
///
/// The index is only an index. Missing, it is rebuilt from the folders; unreadable, or written by a
/// later version, it is set aside — never written over — then rebuilt. An avatar whose folder
/// cannot be read stays listed with why: only the user deletes it.
///
/// The first time, the single avatar of the versions before it (`Avatar/`, #41) is moved in, kept
/// and in use, even unreadable.
public actor FileAvatarLibrary: AvatarLibrary {
  static let indexFileName = "library.json"
  /// What the index is renamed to when it cannot be read: `library.unreadable-<seconds>.json`.
  static let setAsidePrefix = "library.unreadable-"
  /// Folders being written, or kept until a change is known to be whole. Hidden: never listed.
  static let stagingPrefix = ".staging-"
  static let backupPrefix = ".previous-"

  private let directory: URL
  private let legacy: URL?
  private let loadDefaultAvatar: @Sendable () -> AvatarSpriteSet?
  private let now: @Sendable () -> Date
  private let makeID: @Sendable () -> UUID
  private let fileManager = FileManager.default

  /// Read on first use, then kept: the index changes only through this actor.
  private var index: AvatarLibraryIndex?
  /// The legacy avatar already moved in, when the index could not be written after it: it is still
  /// the one in use.
  private var migrated: UUID?
  private var defaultAvatar: AvatarSpriteSet??

  /// - Parameters:
  ///   - directory: `Avatars/`.
  ///   - legacy: `Avatar/`, the single avatar of the versions before the library, moved in once.
  ///   - defaultAvatar: the one shipped with the application, read on first use.
  public init(
    directory: URL, legacy: URL? = nil,
    defaultAvatar: @escaping @Sendable () -> AvatarSpriteSet? = { nil },
    now: @escaping @Sendable () -> Date = Date.init,
    makeID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.directory = directory
    self.legacy = legacy
    self.loadDefaultAvatar = defaultAvatar
    self.now = now
    self.makeID = makeID
  }

  // MARK: - Reading

  public func entries() async throws -> [AvatarLibraryEntry] {
    let index = try prepared()
    let defaultAvatar = defaultAvatarSet()
    let defaultEntry = AvatarLibraryEntry(
      id: .default, state: .kept, manifest: defaultAvatar?.manifest, addedAt: .distantPast,
      problem: defaultAvatar == nil ? .unreadable : nil)
    let stored = index.records.map { record in
      let folder = folder(record.id)
      let manifest = readManifest(in: folder)
      var problem: AvatarStoreError?
      if manifest == nil {
        problem = .unreadable
      } else if record.state == .kept {
        let missing = missingExpressions(in: folder)
        if !missing.isEmpty { problem = .incomplete(missing) }
      }
      return AvatarLibraryEntry(
        id: .stored(record.id), state: record.state, manifest: manifest, addedAt: record.addedAt,
        byteCount: byteCount(of: folder), problem: problem)
    }
    return AvatarLibraryRules.ordered([defaultEntry] + stored)
  }

  public func canCreate() async throws -> Bool { try prepared().canCreate }

  public func load(_ id: AvatarID) async throws -> AvatarSpriteSet {
    guard let uuid = id.storedID else {
      guard let defaultAvatar = defaultAvatarSet() else { throw AvatarStoreError.unreadable }
      return defaultAvatar
    }
    let index = try prepared()
    guard index.record(uuid) != nil else { throw AvatarLibraryError.notFound }
    return try read(uuid)
  }

  public func inUse() async throws -> AvatarID { try prepared().inUse }

  // MARK: - Changing

  public func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID {
    var next = try prepared()
    let id = makeID()
    try next.addDraft(id, basedOn: basedOn, at: now())
    try add(avatar, as: id, indexed: next)
    return .stored(id)
  }

  public func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws {
    let uuid = try prepared().draft(id)
    let backup = try replaceFolder(of: uuid, with: avatar)
    removeQuietly(backup)
  }

  public func draftToComplete(_ id: AvatarID) async throws -> AvatarID {
    _ = try AvatarLibraryRules.modifiable(id)
    let index = try prepared()
    try index.checkKept(id)
    if let existing = index.draft(redrawing: id) { return .stored(existing) }
    return try await saveDraft(try await load(id), basedOn: id)
  }

  public func keep(_ id: AvatarID) async throws -> AvatarID {
    var next = try prepared()
    let uuid = try next.draft(id)
    let draft = try read(uuid)
    switch try next.keep(id, missing: draft.missingExpressions) {
    case .promoted(let kept):
      try commit(next)
      return .stored(kept)
    case .replaced(let original, let draftID):
      // The original keeps its name: only what it looks like, and what it was drawn from, change.
      let replaced =
        readManifest(in: folder(original)).map {
          AvatarLibraryRules.replacing(AvatarSpriteSet(manifest: $0, sprites: [:]), with: draft)
        } ?? draft
      let backup = try replaceFolder(of: original, with: replaced)
      do {
        try commit(next)
      } catch {
        restore(original, from: backup)
        throw error
      }
      removeQuietly(backup)
      removeQuietly(folder(draftID))
      return .stored(original)
    }
  }

  public func rename(_ id: AvatarID, to name: String) async throws {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let kept = AvatarLibraryRules.name(name) else { throw AvatarLibraryError.emptyName }
    let index = try prepared()
    guard index.record(uuid) != nil, isDirectory(folder(uuid)) else {
      throw AvatarLibraryError.notFound
    }
    guard var manifest = readManifest(in: folder(uuid)) else { throw AvatarStoreError.unreadable }
    manifest.name = kept
    try writeFile(
      AvatarImageProcessor.encode(manifest),
      to: folder(uuid).appendingPathComponent(AvatarImageProcessor.manifestFileName))
  }

  public func duplicate(_ id: AvatarID) async throws -> AvatarID {
    var next = try prepared()
    try next.checkKept(id)
    var copy = try await load(id)
    guard copy.isComplete else { throw AvatarLibraryError.incomplete(copy.missingExpressions) }
    copy.manifest.name = AvatarLibraryRules.copyName(
      of: id == .default ? AvatarLibraryRules.defaultAvatarName : copy.manifest.name)
    copy.manifest.source = .imported
    copy.manifest.createdAt = now()
    let uuid = makeID()
    try next.addCopy(uuid, at: now())
    try add(copy, as: uuid, indexed: next)
    return .stored(uuid)
  }

  public func remove(_ id: AvatarID) async throws {
    var next = try prepared()
    try next.remove(id)
    guard let uuid = id.storedID else { return }
    // Moved aside first, so that a failure to write the index puts it back where it was.
    let aside = directory.appendingPathComponent(
      Self.backupPrefix + UUID().uuidString, isDirectory: true)
    let hadFolder = isDirectory(folder(uuid))
    if hadFolder { try fileManager.moveItem(at: folder(uuid), to: aside) }
    do {
      try commit(next)
    } catch {
      if hadFolder { try? fileManager.moveItem(at: aside, to: folder(uuid)) }
      throw error
    }
    if hadFolder { removeQuietly(aside) }
  }

  public func setInUse(_ id: AvatarID) async throws {
    var next = try prepared()
    try next.checkKept(id)
    if let uuid = id.storedID {
      guard readManifest(in: folder(uuid)) != nil else { throw AvatarStoreError.unreadable }
      let missing = missingExpressions(in: folder(uuid))
      guard missing.isEmpty else { throw AvatarLibraryError.incomplete(missing) }
    }
    try next.setInUse(id)
    try commit(next)
  }

  // MARK: - The index

  /// The index, read — or rebuilt, or migrated — the first time.
  private func prepared() throws -> AvatarLibraryIndex {
    if let index { return index }
    try createFolder(directory, intermediate: true)
    removeLeftovers()
    let indexURL = directory.appendingPathComponent(Self.indexFileName)
    let exists = fileManager.fileExists(atPath: indexURL.path)
    var read: AvatarLibraryIndex?
    if exists {
      if let data = try? Data(contentsOf: indexURL),
        let decoded = try? JSONDecoder().decode(AvatarLibraryIndex.self, from: data)
      {
        read = decoded
      } else {
        try setAside(indexURL)
      }
    } else if migrated == nil, let legacy, isDirectory(legacy) {
      // The avatar of an earlier version, whatever state it is in: moved, never copied, so that
      // it is not in two places; on the same volume, a single rename.
      let id = makeID()
      try fileManager.moveItem(at: legacy, to: folder(id))
      migrated = id
    }
    var next = reconciled(read ?? AvatarLibraryIndex())
    if let migrated, !exists { try? next.setInUse(.stored(migrated)) }
    if next != read { next = try writeIndex(next) }
    migrated = nil
    index = next
    return next
  }

  /// The index, made to say what the folders hold: an entry without a folder is dropped, a folder
  /// without an entry is added, kept, in the order it was made.
  private func reconciled(_ index: AvatarLibraryIndex) -> AvatarLibraryIndex {
    let folders = Set(storedFolders())
    var records = index.records.filter { folders.contains($0.id) }
    let known = Set(records.map(\.id))
    let found = folders.subtracting(known).map { (id: $0, date: arrival(of: $0)) }
      .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
    records += found.map { AvatarLibraryIndex.Record(id: $0.id, state: .kept, addedAt: $0.date) }
    return AvatarLibraryIndex(inUse: index.inUse, records: records)
  }

  /// When a folder found without an entry was made: its manifest's date, or the folder's.
  private func arrival(of id: UUID) -> Date {
    if let date = readManifest(in: folder(id))?.createdAt { return date }
    let attributes = try? fileManager.attributesOfItem(atPath: folder(id).path)
    return attributes?[.creationDate] as? Date ?? .distantPast
  }

  /// The folders named after an avatar.
  private func storedFolders() -> [UUID] {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name in
      guard let id = UUID(uuidString: name), id.uuidString == name, isDirectory(folder(id)) else {
        return nil
      }
      return id
    }
  }

  /// Writes the index, then holds it as the library's.
  private func commit(_ next: AvatarLibraryIndex) throws {
    index = try writeIndex(next)
  }

  /// Writes the index, and returns it as it will read back: its dates to the millisecond.
  private func writeIndex(_ index: AvatarLibraryIndex) throws -> AvatarLibraryIndex {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(index)
    try writeFile(data, to: directory.appendingPathComponent(Self.indexFileName))
    return (try? JSONDecoder().decode(AvatarLibraryIndex.self, from: data)) ?? index
  }

  /// Keeps an index this build cannot read beside it, dated, rather than writing over it.
  private func setAside(_ url: URL) throws {
    let stamp = Int(now().timeIntervalSince1970)
    var aside = directory.appendingPathComponent("\(Self.setAsidePrefix)\(stamp).json")
    if fileManager.fileExists(atPath: aside.path) {
      aside = directory.appendingPathComponent(
        "\(Self.setAsidePrefix)\(stamp)-\(UUID().uuidString).json")
    }
    try fileManager.moveItem(at: url, to: aside)
  }

  /// What a change interrupted by the end of the process left: staging folders, and the previous
  /// images of an avatar whose replacement had already been moved in.
  private func removeLeftovers() {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(Self.stagingPrefix) || name.hasPrefix(Self.backupPrefix)
    {
      removeQuietly(directory.appendingPathComponent(name))
    }
  }

  // MARK: - The folders

  func folder(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  /// Writes a new avatar's folder, then the index that lists it; the folder is gone again if the
  /// index cannot be written.
  private func add(_ avatar: AvatarSpriteSet, as id: UUID, indexed next: AvatarLibraryIndex) throws
  {
    let staging = try stage(avatar)
    do {
      try fileManager.moveItem(at: staging, to: folder(id))
    } catch {
      removeQuietly(staging)
      throw error
    }
    do {
      try commit(next)
    } catch {
      removeQuietly(folder(id))
      throw error
    }
  }

  /// Swaps an avatar's folder for one holding `avatar`, in a single step. The previous folder is
  /// kept aside, and returned, until the caller knows the change is whole.
  private func replaceFolder(of id: UUID, with avatar: AvatarSpriteSet) throws -> URL {
    guard isDirectory(folder(id)) else { throw AvatarLibraryError.notFound }
    let staging = try stage(avatar)
    let backupName = Self.backupPrefix + UUID().uuidString
    do {
      _ = try fileManager.replaceItemAt(
        folder(id), withItemAt: staging, backupItemName: backupName,
        options: .withoutDeletingBackupItem)
    } catch {
      removeQuietly(staging)
      throw error
    }
    return directory.appendingPathComponent(backupName, isDirectory: true)
  }

  private func restore(_ id: UUID, from backup: URL) {
    _ = try? fileManager.replaceItemAt(folder(id), withItemAt: backup)
  }

  /// A folder beside the others, hidden, holding `avatar`: moved in once whole.
  private func stage(_ avatar: AvatarSpriteSet) throws -> URL {
    let staging = directory.appendingPathComponent(
      Self.stagingPrefix + UUID().uuidString, isDirectory: true)
    try createFolder(staging, intermediate: false)
    do {
      try Self.write(avatar, into: staging)
    } catch {
      removeQuietly(staging)
      throw error
    }
    return staging
  }

  /// An avatar's files, in a folder that exists.
  static func write(_ avatar: AvatarSpriteSet, into folder: URL) throws {
    try writeFile(
      AvatarImageProcessor.encode(avatar.manifest),
      to: folder.appendingPathComponent(AvatarImageProcessor.manifestFileName))
    for (expression, sprite) in avatar.sprites {
      try writeFile(sprite, to: folder.appendingPathComponent(expression.fileName))
    }
    if let sheet = avatar.sheet {
      try writeFile(sheet, to: folder.appendingPathComponent(AvatarImageProcessor.sheetFileName))
    }
  }

  /// An avatar read back as anything would be: a file changed behind the application's back is not
  /// trusted more for being in its folder. What is missing is left out, and said by the set.
  private func read(_ id: UUID) throws -> AvatarSpriteSet {
    let folder = folder(id)
    guard isDirectory(folder) else { throw AvatarLibraryError.notFound }
    guard let manifest = readManifest(in: folder) else { throw AvatarStoreError.unreadable }
    var sprites: [AvatarExpression: Data] = [:]
    for expression in AvatarExpression.allCases {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(expression.fileName))
      else { continue }
      guard let image = try? ImageCodec.decode(data),
        image.width == AvatarSpriteSet.spriteSide, image.height == AvatarSpriteSet.spriteSide
      else { throw AvatarStoreError.unreadable }
      sprites[expression] = data
    }
    let sheet = try? Data(
      contentsOf: folder.appendingPathComponent(AvatarImageProcessor.sheetFileName))
    return AvatarSpriteSet(manifest: manifest, sprites: sprites, sheet: sheet)
  }

  private func readManifest(in folder: URL) -> AvatarManifest? {
    let url = folder.appendingPathComponent(AvatarImageProcessor.manifestFileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? AvatarImageProcessor.manifest(from: data)
  }

  /// The expressions without a file: cheap enough for the list, which does not decode an image.
  private func missingExpressions(in folder: URL) -> [AvatarExpression] {
    AvatarExpression.allCases.filter {
      !fileManager.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
    }
  }

  private func byteCount(of folder: URL) -> Int64 {
    let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.reduce(0) { total, name in
      let attributes = try? fileManager.attributesOfItem(
        atPath: folder.appendingPathComponent(name).path)
      return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }
  }

  private func defaultAvatarSet() -> AvatarSpriteSet? {
    if let defaultAvatar { return defaultAvatar }
    let loaded = loadDefaultAvatar()
    defaultAvatar = .some(loaded)
    return loaded
  }

  // MARK: - Files

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// A folder only its owner reads. One that already exists keeps its own mode.
  private func createFolder(_ url: URL, intermediate: Bool) throws {
    guard !isDirectory(url) else { return }
    try fileManager.createDirectory(
      at: url, withIntermediateDirectories: intermediate, attributes: [.posixPermissions: 0o700])
  }

  private func removeQuietly(_ url: URL) {
    try? fileManager.removeItem(at: url)
  }

  /// Written whole or not at all, then readable by its owner only.
  private static func writeFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func writeFile(_ data: Data, to url: URL) throws {
    try Self.writeFile(data, to: url)
  }
}
