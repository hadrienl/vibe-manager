import Foundation
import Testing
import VibeApplication
import VibeAvatarLibraryTesting

@testable import VibeAvatar

/// A folder of its own for each test, removed after it.
final class TemporaryFolder: @unchecked Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "avatar-library-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    // Folders a test made read-only are made writable again first.
    if let items = FileManager.default.enumerator(atPath: url.path) {
      for case let item as String in items {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: url.appendingPathComponent(item).path)
      }
    }
    try? FileManager.default.removeItem(at: url)
  }

  var library: URL { url.appendingPathComponent("Avatars", isDirectory: true) }
  var legacy: URL { url.appendingPathComponent("Avatar", isDirectory: true) }
  var index: URL { library.appendingPathComponent("library.json") }
}

/// Sprites the library reads back: 512 × 512 PNGs, told apart by the colour of one pixel.
enum TestSprites {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var made: [UInt8: Data] = [:]

  static func sprite(_ marker: UInt8) -> Data {
    lock.withLock {
      if let data = made[marker] { return data }
      let side = AvatarSpriteSet.spriteSide
      var image = RGBAImage(width: side, height: side)
      image.pixels[0] = marker
      image.pixels[3] = 255
      let data = (try? ImageCodec.png(image)) ?? Data()
      made[marker] = data
      return data
    }
  }
}

@Suite("The library of avatars on disk")
struct FileAvatarLibraryTests {
  static let contract = AvatarLibraryContract(sprite: TestSprites.sprite) {
    defaultAvatar, kept, now in
    let folder = TemporaryFolder()
    // Kept avatars as another version wrote them: folders without an index, which reads them.
    for var avatar in kept {
      avatar.manifest.createdAt = now()
      try FileAvatarLibraryTests.writeFolder(avatar, in: folder)
    }
    return KeepingAlive(
      library: FileAvatarLibrary(
        directory: folder.library, defaultAvatar: { defaultAvatar }, now: now),
      folder: folder)
  }

  var contract: AvatarLibraryContract { Self.contract }

  @Test("It does what every library does", arguments: AvatarLibraryContract.Case.allCases)
  func contract(_ contractCase: AvatarLibraryContract.Case) async throws {
    try await Self.contract.run(contractCase)
  }

  @discardableResult
  static func writeFolder(_ avatar: AvatarSpriteSet, in folder: TemporaryFolder) throws -> UUID {
    let id = UUID()
    let url = folder.library.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileAvatarLibrary.write(avatar, into: url)
    return id
  }

  func library(_ folder: TemporaryFolder, legacy: Bool = false) -> FileAvatarLibrary {
    FileAvatarLibrary(
      directory: folder.library, legacy: legacy ? folder.legacy : nil,
      defaultAvatar: { [contract] in contract.avatar("Placeholder") })
  }

  func mode(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  }

  func names(in url: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
  }

  // MARK: - On disk

  @Test("What was written reads back the same after a relaunch")
  func roundTrip() async throws {
    let folder = TemporaryFolder()
    let first = library(folder)
    let fox = try await first.saveDraft(contract.avatar("Fox", marker: 4), basedOn: nil)
    _ = try await first.keep(fox)
    try await first.setInUse(fox)
    var robot = contract.avatar("Robot", marker: 5)
    robot.sheet = TestSprites.sprite(6)
    let draft = try await first.saveDraft(robot, basedOn: fox)

    let second = library(folder)
    #expect(try await second.entries() == first.entries())
    #expect(try await second.inUse() == fox)
    #expect(try await second.load(fox) == contract.avatar("Fox", marker: 4))
    #expect(try await second.load(draft) == robot)
    #expect(try await second.entries().last?.state == .draft(basedOn: fox))

    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: folder.index)) as? [String: Any])
    #expect(json["format"] as? Int == 1)
    #expect(json["inUse"] as? String == fox.description)
  }

  @Test("Folders only their owner opens, files only their owner reads")
  func permissions() async throws {
    let folder = TemporaryFolder()
    let library = library(folder)
    var avatar = contract.avatar("Fox")
    avatar.sheet = TestSprites.sprite(2)
    let fox = try await library.saveDraft(avatar, basedOn: nil)
    try await library.rename(fox, to: "Renard")
    let avatarFolder = folder.library.appendingPathComponent(fox.description)

    #expect(try mode(folder.library) == 0o700)
    #expect(try mode(avatarFolder) == 0o700)
    #expect(try mode(folder.index) == 0o600)
    for name in try names(in: avatarFolder) {
      #expect(try mode(avatarFolder.appendingPathComponent(name)) == 0o600, "\(name)")
    }
    #expect(try names(in: avatarFolder).contains("sheet.png"))
  }

  @Test("Nothing is left beside the avatars: no staging folder, no previous images")
  func noLeftovers() async throws {
    let folder = TemporaryFolder()
    let library = library(folder)
    let fox = try await library.saveDraft(contract.avatar("Fox"), basedOn: nil)
    _ = try await library.keep(fox)
    let draft = try await library.saveDraft(contract.avatar("Fox", marker: 2), basedOn: fox)
    try await library.updateDraft(draft, with: contract.avatar("Fox", marker: 3))
    _ = try await library.keep(draft)
    let copy = try await library.duplicate(fox)
    try await library.remove(copy)
    #expect(try names(in: folder.library) == ["library.json", fox.description])
  }

  @Test("What an interrupted change left is cleared at the next launch, and nothing else")
  func interruptedLeftovers() async throws {
    let folder = TemporaryFolder()
    let fox = try Self.writeFolder(contract.avatar("Fox"), in: folder)
    for name in [".staging-\(UUID().uuidString)", ".previous-\(UUID().uuidString)"] {
      try FileManager.default.createDirectory(
        at: folder.library.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    #expect(try await library(folder).entries().count == 2)
    #expect(try names(in: folder.library) == ["library.json", fox.uuidString])
  }

  @Test("A change that cannot be written leaves the library as it was")
  func failedWrite() async throws {
    let folder = TemporaryFolder()
    let library = library(folder)
    let fox = try await library.duplicate(.default)
    try await library.setInUse(fox)
    let before = try await library.entries()
    // The index can no longer be replaced: a folder stands where it is.
    try FileManager.default.removeItem(at: folder.index)
    try FileManager.default.createDirectory(at: folder.index, withIntermediateDirectories: false)

    await #expect(throws: (any Error).self) {
      _ = try await library.saveDraft(contract.avatar("Robot"), basedOn: nil)
    }
    await #expect(throws: (any Error).self) { try await library.remove(fox) }
    await #expect(throws: (any Error).self) { try await library.setInUse(.default) }
    #expect(try await library.entries() == before)
    #expect(try await library.inUse() == fox)
    #expect(try names(in: folder.library) == ["library.json", fox.description])
    #expect(try await library.load(fox).isComplete)
  }

  @Test("Kept, a redrawing draft whose index cannot be written leaves the original's images")
  func failedReplacement() async throws {
    let folder = TemporaryFolder()
    let library = library(folder)
    let fox = try await library.saveDraft(contract.avatar("Fox", marker: 1), basedOn: nil)
    _ = try await library.keep(fox)
    let draft = try await library.saveDraft(contract.avatar("Fox", marker: 2), basedOn: fox)
    try FileManager.default.removeItem(at: folder.index)
    try FileManager.default.createDirectory(at: folder.index, withIntermediateDirectories: false)

    await #expect(throws: (any Error).self) { _ = try await library.keep(draft) }
    #expect(try await library.load(fox).sprites[.neutral] == TestSprites.sprite(1))
    #expect(try await library.load(draft).sprites[.neutral] == TestSprites.sprite(2))
    #expect(
      try names(in: folder.library) == ["library.json", fox.description, draft.description])
  }

  // MARK: - The index

  @Test("Without its index, the library is rebuilt from its folders, in the order they were made")
  func missingIndex() async throws {
    let folder = TemporaryFolder()
    var older = contract.avatar("Older")
    older.manifest.createdAt = Date(timeIntervalSince1970: 1_000)
    var newer = contract.avatar("Newer")
    newer.manifest.createdAt = Date(timeIntervalSince1970: 2_000)
    let newerID = try Self.writeFolder(newer, in: folder)
    let olderID = try Self.writeFolder(older, in: folder)
    // Not an avatar's: left alone.
    try FileManager.default.createDirectory(
      at: folder.library.appendingPathComponent("Notes"), withIntermediateDirectories: false)

    let library = library(folder)
    let entries = try await library.entries()
    #expect(entries.map(\.id) == [.default, .stored(olderID), .stored(newerID)])
    #expect(entries.allSatisfy { $0.state == .kept })
    #expect(try await library.inUse() == .default)
    #expect(FileManager.default.fileExists(atPath: folder.index.path))
    #expect(try names(in: folder.library).contains("Notes"))
  }

  @Test("A folder the index does not know is added, kept; an entry without a folder is dropped")
  func reconciled() async throws {
    let folder = TemporaryFolder()
    let first = library(folder)
    let fox = try await first.duplicate(.default)
    let gone = try await first.duplicate(.default)
    try await first.setInUse(gone)
    try FileManager.default.removeItem(
      at: folder.library.appendingPathComponent(gone.description))
    let found = try Self.writeFolder(contract.avatar("Found"), in: folder)

    let second = library(folder)
    #expect(try await second.entries().map(\.id) == [.default, fox, .stored(found)])
    #expect(try await second.inUse() == .default)
  }

  @Test(
    "An index that cannot be read is set aside, never written over, and rebuilt",
    arguments: ["{ not json", #"{ "format": 2, "inUse": "default", "entries": [] }"#])
  func unreadableIndex(_ contents: String) async throws {
    let folder = TemporaryFolder()
    let fox = try Self.writeFolder(contract.avatar("Fox"), in: folder)
    try Data(contents.utf8).write(to: folder.index)

    let library = library(folder)
    #expect(try await library.entries().map(\.id) == [.default, .stored(fox)])
    let aside = try names(in: folder.library).filter { $0.hasPrefix("library.unreadable-") }
    #expect(aside.count == 1)
    let kept = try Data(
      contentsOf: folder.library.appendingPathComponent(try #require(aside.first)))
    #expect(String(decoding: kept, as: UTF8.self) == contents)
    #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.index)) is [String: Any])
  }

  @Test("An avatar that cannot be read stays listed with why, and is not deleted")
  func unreadableAvatar() async throws {
    let folder = TemporaryFolder()
    let broken = try Self.writeFolder(contract.avatar("Broken"), in: folder)
    let brokenFolder = folder.library.appendingPathComponent(broken.uuidString)
    try Data("{".utf8).write(to: brokenFolder.appendingPathComponent("manifest.json"))
    let damaged = try Self.writeFolder(contract.avatar("Damaged"), in: folder)
    try Data("not a png".utf8).write(
      to: folder.library.appendingPathComponent(damaged.uuidString)
        .appendingPathComponent("neutral.png"))

    let library = library(folder)
    let entry = try #require(try await library.entries().first { $0.id == .stored(broken) })
    #expect(entry.problem == .unreadable)
    await #expect(throws: AvatarStoreError.unreadable) {
      _ = try await library.load(.stored(broken))
    }
    await #expect(throws: AvatarStoreError.unreadable) {
      try await library.setInUse(.stored(broken))
    }
    await #expect(throws: AvatarStoreError.unreadable) {
      _ = try await library.load(.stored(damaged))
    }
    #expect(FileManager.default.fileExists(atPath: brokenFolder.path))
    #expect(try await self.library(folder).entries().count == 3)
  }

  // MARK: - Migration

  func writeLegacy(_ avatar: AvatarSpriteSet, in folder: TemporaryFolder) throws {
    try FileManager.default.createDirectory(
      at: folder.legacy, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileAvatarLibrary.write(avatar, into: folder.legacy)
  }

  @Test("The avatar of an earlier version is moved in, kept and in use")
  func migration() async throws {
    let folder = TemporaryFolder()
    try writeLegacy(contract.avatar("Mine", marker: 7), in: folder)

    let library = library(folder, legacy: true)
    let store = LibraryAvatarStore(library: library)
    #expect(try await store.load() == contract.avatar("Mine", marker: 7))
    let entries = try await library.entries()
    #expect(entries.count == 2)
    #expect(entries.last?.state == .kept)
    #expect(try await library.inUse() == entries.last?.id)
    #expect(!FileManager.default.fileExists(atPath: folder.legacy.path))
    #expect(
      try mode(folder.library.appendingPathComponent(try #require(entries.last).id.description))
        == 0o700)
  }

  @Test("Relaunched, the migration is not done again")
  func migrationOnce() async throws {
    let folder = TemporaryFolder()
    try writeLegacy(contract.avatar("Mine"), in: folder)
    let first = try await library(folder, legacy: true).entries()
    let second = library(folder, legacy: true)
    #expect(try await second.entries() == first)
    #expect(try await second.inUse() == first.last?.id)
  }

  @Test("An unreadable avatar of an earlier version is moved in all the same, listed with why")
  func migrationUnreadable() async throws {
    let folder = TemporaryFolder()
    try FileManager.default.createDirectory(at: folder.legacy, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: folder.legacy.appendingPathComponent("manifest.json"))
    try Data("not a png".utf8).write(to: folder.legacy.appendingPathComponent("neutral.png"))

    let library = library(folder, legacy: true)
    let entry = try #require(try await library.entries().last)
    #expect(entry.id != .default)
    #expect(entry.problem == .unreadable)
    // As before: the default avatar is shown, and why.
    await #expect(throws: AvatarStoreError.unreadable) {
      _ = try await LibraryAvatarStore(library: library).load()
    }
    #expect(!FileManager.default.fileExists(atPath: folder.legacy.path))
    #expect(
      try names(in: folder.library.appendingPathComponent(entry.id.description))
        == ["manifest.json", "neutral.png"])
  }

  @Test("An incomplete avatar of an earlier version is moved in, and says what it lacks")
  func migrationIncomplete() async throws {
    let folder = TemporaryFolder()
    try writeLegacy(contract.avatar("Old", missing: [.thinking]), in: folder)
    let library = library(folder, legacy: true)
    #expect(try await library.entries().last?.problem == .incomplete([.thinking]))
    await #expect(throws: AvatarStoreError.incomplete([.thinking])) {
      _ = try await LibraryAvatarStore(library: library).load()
    }
  }

  @Test("No avatar of an earlier version: an empty library, the default avatar in use")
  func noLegacy() async throws {
    let folder = TemporaryFolder()
    let library = library(folder, legacy: true)
    #expect(try await library.entries().map(\.id) == [.default])
    #expect(try await library.inUse() == .default)
    #expect(try names(in: folder.library) == ["library.json"])
  }

  @Test("A library already there leaves the earlier version's folder alone")
  func libraryAlreadyThere() async throws {
    let folder = TemporaryFolder()
    _ = try await library(folder).entries()
    try writeLegacy(contract.avatar("Later"), in: folder)
    let library = library(folder, legacy: true)
    #expect(try await library.entries().map(\.id) == [.default])
    #expect(FileManager.default.fileExists(atPath: folder.legacy.path))
  }

  @Test("A migration interrupted before the move is taken up again")
  func interruptedMigration() async throws {
    let folder = TemporaryFolder()
    try FileManager.default.createDirectory(at: folder.library, withIntermediateDirectories: true)
    try writeLegacy(contract.avatar("Mine"), in: folder)
    let library = library(folder, legacy: true)
    #expect(try await library.entries().count == 2)
    #expect(try await library.inUse() != .default)
  }

  @Test("An avatar in use that lost a file since says which, as the single avatar did")
  func inUseLostFile() async throws {
    let folder = TemporaryFolder()
    try await LibraryAvatarStore(library: library(folder)).save(contract.avatar("Fox"))
    let fox = try await library(folder).inUse()
    try FileManager.default.removeItem(
      at: folder.library.appendingPathComponent(fox.description)
        .appendingPathComponent("thinking.png"))
    let store = LibraryAvatarStore(library: library(folder))
    await #expect(throws: AvatarStoreError.incomplete([.thinking])) { _ = try await store.load() }
  }
}

/// A library that holds on to its folder for as long as the test uses it.
private struct KeepingAlive: AvatarLibrary {
  let library: FileAvatarLibrary
  let folder: TemporaryFolder

  func entries() async throws -> [AvatarLibraryEntry] { try await library.entries() }
  func canCreate() async throws -> Bool { try await library.canCreate() }
  func load(_ id: AvatarID) async throws -> AvatarSpriteSet { try await library.load(id) }
  func saveDraft(_ avatar: AvatarSpriteSet, basedOn: AvatarID?) async throws -> AvatarID {
    try await library.saveDraft(avatar, basedOn: basedOn)
  }
  func updateDraft(_ id: AvatarID, with avatar: AvatarSpriteSet) async throws {
    try await library.updateDraft(id, with: avatar)
  }
  func draftToComplete(_ id: AvatarID) async throws -> AvatarID {
    try await library.draftToComplete(id)
  }
  func keep(_ id: AvatarID) async throws -> AvatarID { try await library.keep(id) }
  func rename(_ id: AvatarID, to name: String) async throws {
    try await library.rename(id, to: name)
  }
  func duplicate(_ id: AvatarID) async throws -> AvatarID { try await library.duplicate(id) }
  func remove(_ id: AvatarID) async throws { try await library.remove(id) }
  func inUse() async throws -> AvatarID { try await library.inUse() }
  func setInUse(_ id: AvatarID) async throws { try await library.setInUse(id) }
}
