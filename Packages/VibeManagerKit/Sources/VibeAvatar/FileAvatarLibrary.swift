import Darwin
import Foundation
import VibeApplication

/// The library of avatars on disk (#154), in `Avatars/` beside the session store:
///
/// ```
/// Avatars/
///   library.json          the index: which avatars, in which state, which one is in use
///   library.lock          held while the library is changed
///   <uuid>/manifest.json  the same manifest as an archive's
///   <uuid>/neutral.png …  the sprites, 512 × 512
///   <uuid>/sheet.png      the sheet they were cut from, when there is one
/// ```
///
/// Folders are `0700`, files `0600`. An avatar is written in a staging folder, then moved in with
/// a single rename; `library.json` is rewritten after it, atomically. Every change holds
/// `library.lock` and reads the index again first, so that another instance of the application on
/// the same data is neither written over nor cleaned up after.
///
/// What was made is never lost: an avatar whose index could not be written after it keeps its
/// folder, and the next reading of the folders takes it back, kept. The change still says it
/// failed.
///
/// The index is only an index. Missing, it is rebuilt from the folders; unreadable, or written by a
/// later version, it is set aside — never written over — then rebuilt. An avatar whose folder
/// cannot be read stays listed with why: only the user deletes it.
///
/// The single avatar of the versions before the library (`Avatar/`, #41) is taken in, kept and in
/// use, even unreadable: at the first launch, and again whenever an earlier version wrote one
/// since — it is the user's latest choice. It is copied in, the index written with a mark of the
/// folder taken, and only then is `Avatar/` renamed away in one step: an interruption starts over,
/// at worst with a second copy, never with less; a folder that cannot be moved is not taken twice.
///
/// Readings go back to `library.json` when another instance rewrote it, without the lock.
public actor FileAvatarLibrary: AvatarLibrary {
  static let indexFileName = "library.json"
  static let lockFileName = "library.lock"
  /// What the index is renamed to when it cannot be read: `library.unreadable-<seconds>.json`.
  static let setAsidePrefix = "library.unreadable-"
  /// Folders being written, or kept until a change is known to be whole. Hidden: never listed, and
  /// cleared, under the lock, once their change is over.
  static let stagingPrefix = ".staging-"
  static let backupPrefix = ".previous-"
  /// An avatar's previous folder that could not be put back: kept, out of the way, never cleared.
  static let recoveredPrefix = "recovered-"

  private let directory: URL
  private let legacy: URL?
  private let loadDefaultAvatar: @Sendable () -> AvatarSpriteSet?
  private let now: @Sendable () -> Date
  private let makeID: @Sendable () -> UUID
  private let fileManager = FileManager.default
  private let writeIndexFile: @Sendable (Data, URL) throws -> Void
  private let diagnostics: Diagnostics
  private let lockTimeout: Duration

  /// Another instance held the library longer than it takes to change it.
  public struct Busy: Error, Hashable {}

  /// The index as last read or written; every change reads it again under the lock.
  private var index: AvatarLibraryIndex?
  /// `library.json` as it was when `index` was read or written: another inode, or another date,
  /// and it is read again.
  private var indexStamp: AvatarLibraryIndex.LegacyMark?
  /// Why the library changes nothing: an index it could not read, nor set aside.
  private var readOnly: (any Error)?
  /// The legacy avatar already copied in, while the index that uses it is not written yet: not
  /// copied a second time.
  private var legacyCopy: UUID?
  private var defaultAvatar: AvatarSpriteSet??

  /// - Parameters:
  ///   - directory: `Avatars/`.
  ///   - legacy: `Avatar/`, the single avatar of the versions before the library.
  ///   - defaultAvatar: the one shipped with the application, read on first use.
  ///   - writeIndexFile: writes `library.json`; atomically, `0600`, unless a test says otherwise.
  public init(
    directory: URL, legacy: URL? = nil,
    defaultAvatar: @escaping @Sendable () -> AvatarSpriteSet? = { nil },
    diagnostics: Diagnostics = .disabled,
    lockTimeout: Duration = .seconds(5),
    now: @escaping @Sendable () -> Date = Date.init,
    makeID: @escaping @Sendable () -> UUID = UUID.init,
    writeIndexFile: (@Sendable (Data, URL) throws -> Void)? = nil
  ) {
    self.directory = directory
    self.legacy = legacy
    self.loadDefaultAvatar = defaultAvatar
    self.diagnostics = diagnostics
    self.lockTimeout = lockTimeout
    self.now = now
    self.makeID = makeID
    self.writeIndexFile = writeIndexFile ?? { data, url in try Self.writeFile(data, to: url) }
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
    try loadSet(id, in: try prepared())
  }

  public func inUse() async throws -> AvatarID { try prepared().inUse }

  // MARK: - Changing

  public func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID {
    try changing { current in try addDraft(avatar, basedOn: basedOn, to: current) }
  }

  public func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws {
    try changing { current in
      let uuid = try current.draft(id)
      let backup = try replaceFolder(of: uuid, with: avatar)
      removeQuietly(backup)
    }
  }

  public func draftToComplete(_ id: AvatarID) async throws -> AvatarID {
    _ = try AvatarLibraryRules.modifiable(id)
    return try changing { current in
      try current.checkKept(id)
      if let existing = current.draft(redrawing: id) { return .stored(existing) }
      return try addDraft(try loadSet(id, in: current), basedOn: id, to: current)
    }
  }

  public func keep(_ id: AvatarID) async throws -> AvatarID {
    try changing { current in
      var next = current
      let uuid = try next.draft(id)
      let draft = try read(uuid)
      switch try next.keep(id, missing: draft.missingExpressions) {
      case .promoted(let kept):
        try commit(next)
        return .stored(kept)
      case .replaced(let original, let draftID):
        // The original keeps its name: only what it looks like, and what it was drawn from,
        // change.
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
  }

  public func rename(_ id: AvatarID, to name: String) async throws {
    let uuid = try AvatarLibraryRules.modifiable(id)
    guard let kept = AvatarLibraryRules.name(name) else { throw AvatarLibraryError.emptyName }
    try changing { current in
      guard current.record(uuid) != nil, isDirectory(folder(uuid)) else {
        throw AvatarLibraryError.notFound
      }
      guard var manifest = readManifest(in: folder(uuid)) else {
        throw AvatarStoreError.unreadable
      }
      manifest.name = kept
      try writeFile(
        AvatarImageProcessor.encode(manifest),
        to: folder(uuid).appendingPathComponent(AvatarImageProcessor.manifestFileName))
    }
  }

  public func duplicate(_ id: AvatarID) async throws -> AvatarID {
    try changing { current in
      var next = current
      try next.checkKept(id)
      var copy = try loadSet(id, in: current)
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
  }

  public func remove(_ id: AvatarID) async throws {
    try changing { current in
      var next = current
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
        if hadFolder { restore(uuid, from: aside) }
        throw error
      }
      if hadFolder { removeQuietly(aside) }
    }
  }

  public func setInUse(_ id: AvatarID) async throws {
    try changing { current in
      var next = current
      try next.checkKept(id)
      if let uuid = id.storedID {
        guard readManifest(in: folder(uuid)) != nil else { throw AvatarStoreError.unreadable }
        let missing = missingExpressions(in: folder(uuid))
        guard missing.isEmpty else { throw AvatarLibraryError.incomplete(missing) }
      }
      try next.setInUse(id)
      try commit(next)
    }
  }

  private func addDraft(
    _ avatar: AvatarSpriteSet, basedOn: AvatarID?, to current: AvatarLibraryIndex
  ) throws -> AvatarID {
    var next = current
    let id = makeID()
    try next.addDraft(id, basedOn: basedOn, at: now())
    try add(avatar, as: id, indexed: next)
    return .stored(id)
  }

  private func loadSet(_ id: AvatarID, in index: AvatarLibraryIndex) throws -> AvatarSpriteSet {
    guard let uuid = id.storedID else {
      guard let defaultAvatar = defaultAvatarSet() else { throw AvatarStoreError.unreadable }
      return defaultAvatar
    }
    guard index.record(uuid) != nil else { throw AvatarLibraryError.notFound }
    return try read(uuid)
  }

  // MARK: - The index

  /// The index as last read. Read again, without the lock, when another instance rewrote it; under
  /// the lock — rebuilt, migrated — when it is missing, unreadable, or `Avatar/` is to be taken.
  private func prepared() throws -> AvatarLibraryIndex {
    let indexPath = indexURL.path
    if let index, Self.stamp(of: indexPath) == indexStamp, !legacyWaiting(for: index) {
      return index
    }
    if fileManager.fileExists(atPath: indexPath) {
      let stamp = Self.stamp(of: indexPath)
      // A reading error is not a damaged index: nothing is touched, the caller is told.
      let data = try Data(contentsOf: indexURL)
      if let read = try? JSONDecoder().decode(AvatarLibraryIndex.self, from: data),
        !legacyWaiting(for: read)
      {
        let next = reconciled(read)
        index = next
        indexStamp = stamp
        return next
      }
    }
    return try locked { try refreshed() }
  }

  /// Runs a change under the lock, from the index as it is on disk now.
  private func changing<T>(_ change: (AvatarLibraryIndex) throws -> T) throws -> T {
    try locked {
      let current = try refreshed()
      if let readOnly { throw readOnly }
      return try change(current)
    }
  }

  /// The index read again, made to say what the folders hold, the legacy avatar taken in; written
  /// back when that changed it. Called under the lock only.
  private func refreshed() throws -> AvatarLibraryIndex {
    index = nil
    readOnly = nil
    removeLeftovers()
    let stamp = Self.stamp(of: indexURL.path)
    var read: AvatarLibraryIndex?
    if fileManager.fileExists(atPath: indexURL.path) {
      // Unreadable is not undecodable: a reading error changes nothing, and is said.
      let data = try Data(contentsOf: indexURL)
      if let decoded = try? JSONDecoder().decode(AvatarLibraryIndex.self, from: data) {
        read = decoded
      } else {
        do {
          try setAside(indexURL)
        } catch {
          // The damaged index stays where it is, never written over: the library is read from
          // its folders, and changes nothing until it can be set aside.
          readOnly = error
          let next = reconciled(AvatarLibraryIndex())
          index = next
          indexStamp = stamp
          return next
        }
      }
    }
    var next = reconciled(read ?? AvatarLibraryIndex())
    let tookLegacy = takeLegacy(into: &next)
    if next != read { next = try writeIndex(next) } else { indexStamp = stamp }
    if tookLegacy { moveLegacyAway() }
    index = next
    return next
  }

  /// Whether `Avatar/` holds an avatar the library has not taken yet: there, and not the folder
  /// the index says was taken.
  private func legacyWaiting(for index: AvatarLibraryIndex) -> Bool {
    guard let legacy, isDirectory(legacy) else { return false }
    return Self.stamp(of: legacy.path) != index.legacy
  }

  /// Copies `Avatar/`, whatever state it is in, into the library, kept and in use, and marks it
  /// taken. Nothing is taken when it cannot be copied: `Avatar/` stays, and is tried again at the
  /// next change.
  private func takeLegacy(into index: inout AvatarLibraryIndex) -> Bool {
    guard let legacy, legacyWaiting(for: index), let mark = Self.stamp(of: legacy.path) else {
      return false
    }
    let id: UUID
    if let copied = legacyCopy, isDirectory(folder(copied)) {
      id = copied
    } else {
      id = makeID()
      let staging = directory.appendingPathComponent(
        Self.stagingPrefix + UUID().uuidString, isDirectory: true)
      do {
        // A clone on APFS: nothing is read or written twice.
        try fileManager.copyItem(at: legacy, to: staging)
        secure(staging)
        try fileManager.moveItem(at: staging, to: folder(id))
      } catch {
        removeQuietly(staging)
        diagnostics.record(
          .store, .error, "avatar.legacyCopyFailed", ["code": Self.code(of: error)])
        return false
      }
      legacyCopy = id
    }
    let record = index.record(id) ?? .init(id: id, state: .kept, addedAt: now())
    index = AvatarLibraryIndex(
      inUse: .stored(id),
      records: index.records.filter { $0.id != id }
        + [.init(id: id, state: .kept, addedAt: record.addedAt)],
      legacy: mark)
    return true
  }

  /// `Avatar/` out of the way, now that the index uses its copy: renamed in one step beside the
  /// leftovers, never deleted in place, so that it is never found half emptied. Should the rename
  /// fail, it stays, and the index's mark keeps it from being taken again while it is unchanged.
  private func moveLegacyAway() {
    guard let legacy else { return }
    do {
      try fileManager.moveItem(
        at: legacy,
        to: directory.appendingPathComponent(
          "\(Self.backupPrefix)legacy-\(UUID().uuidString)", isDirectory: true))
      legacyCopy = nil
    } catch {
      diagnostics.record(.store, .notice, "avatar.legacyNotMoved", ["code": Self.code(of: error)])
    }
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
    return AvatarLibraryIndex(inUse: index.inUse, records: records, legacy: index.legacy)
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

  /// Writes the index, then holds it as the library's. Should it fail, the next reading goes back
  /// to the disk, and finds what the change left there.
  private func commit(_ next: AvatarLibraryIndex) throws {
    do {
      index = try writeIndex(next)
    } catch {
      index = nil
      throw error
    }
  }

  /// Writes the index, and returns it as it will read back: its dates to the millisecond.
  private func writeIndex(_ index: AvatarLibraryIndex) throws -> AvatarLibraryIndex {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(index)
    try writeIndexFile(data, indexURL)
    indexStamp = Self.stamp(of: indexURL.path)
    return (try? JSONDecoder().decode(AvatarLibraryIndex.self, from: data)) ?? index
  }

  private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

  /// What tells a file or a folder apart from the one there before: its inode, and when it last
  /// changed. A file written atomically is a new inode.
  static func stamp(of path: String) -> AvatarLibraryIndex.LegacyMark? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let modified = info.st_mtimespec
    return AvatarLibraryIndex.LegacyMark(
      inode: UInt64(info.st_ino),
      modifiedNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec))
  }

  private static func code(of error: any Error) -> DiagnosticValue {
    let error = error as NSError
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    return .code(Int32(truncatingIfNeeded: underlying?.code ?? error.code))
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

  /// What a change interrupted by the end of its process left: staging folders, the previous
  /// images of an avatar whose replacement had already been moved in, the old `Avatar/` once
  /// taken. Under the lock, no other change is under way.
  private func removeLeftovers() {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(Self.stagingPrefix) || name.hasPrefix(Self.backupPrefix)
    {
      removeQuietly(directory.appendingPathComponent(name))
    }
  }

  /// Runs `body` holding `library.lock`: one change at a time, whichever instance makes it. The
  /// lock goes with the file's descriptor, even when the process ends. Never waited for forever:
  /// past `lockTimeout`, `FileAvatarLibrary.Busy`.
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try createFolder(directory, intermediate: true)
    let path = directory.appendingPathComponent(Self.lockFileName).path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let deadline = ContinuousClock.now + lockTimeout
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EWOULDBLOCK || code == EINTR else {
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      guard ContinuousClock.now < deadline else { throw Busy() }
      usleep(10_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  // MARK: - The folders

  func folder(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  /// Writes a new avatar's folder, then the index that lists it. Should the index fail, the folder
  /// stays: what was made is not lost, and the next reading of the folders takes it back.
  private func add(_ avatar: AvatarSpriteSet, as id: UUID, indexed next: AvatarLibraryIndex) throws
  {
    let staging = try stage(avatar)
    do {
      try fileManager.moveItem(at: staging, to: folder(id))
    } catch {
      removeQuietly(staging)
      throw error
    }
    try commit(next)
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

  /// Puts an avatar's previous folder back. Should that fail, it is kept under a name nothing
  /// clears, rather than lost with the leftovers.
  private func restore(_ id: UUID, from backup: URL) {
    do {
      if isDirectory(folder(id)) {
        _ = try fileManager.replaceItemAt(folder(id), withItemAt: backup)
      } else {
        try fileManager.moveItem(at: backup, to: folder(id))
      }
    } catch {
      try? fileManager.moveItem(
        at: backup,
        to: directory.appendingPathComponent(
          "\(Self.recoveredPrefix)\(id.uuidString)-\(UUID().uuidString)", isDirectory: true))
    }
  }

  /// Folders `0700` and files `0600`, all the way down: what came from elsewhere is made as private
  /// as what the library writes.
  private func secure(_ folder: URL) {
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    guard let items = fileManager.enumerator(atPath: folder.path) else { return }
    for case let item as String in items {
      let path = folder.appendingPathComponent(item).path
      let mode = isDirectory(URL(fileURLWithPath: path)) ? 0o700 : 0o600
      try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
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
