import Foundation
import Testing
import VibeApplication
import VibePersistence

@testable import VibeAvatar

/// A zip written entry by entry, with whatever a hostile archive may say of each.
struct HandMadeZip {
  struct Entry {
    var name: String
    var contents: Data
    var mode: UInt32 = 0o100644
    var flags: UInt16 = 0
    /// The size declared, when it is not the true one.
    var declaredSize: UInt32?
  }

  var entries: [Entry]

  func data() -> Data {
    var archive = Data()
    var directory = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      let offset = UInt32(archive.count)
      let size = UInt32(entry.contents.count)
      let crc = CRC32.checksum(entry.contents)
      archive.append(le32(0x0403_4B50))
      archive.append(contentsOf: le16(20) + le16(entry.flags) + le16(0) + le16(0) + le16(0))
      archive.append(le32(crc) + le32(size) + le32(entry.declaredSize ?? size))
      archive.append(le16(UInt16(name.count)) + le16(0))
      archive.append(name)
      archive.append(entry.contents)
      directory.append(le32(0x0201_4B50))
      directory.append(le16(0x031E) + le16(20) + le16(entry.flags) + le16(0) + le16(0) + le16(0))
      directory.append(le32(crc) + le32(size) + le32(entry.declaredSize ?? size))
      directory.append(le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0))
      directory.append(le32(entry.mode << 16) + le32(offset))
      directory.append(name)
    }
    let directoryOffset = UInt32(archive.count)
    archive.append(directory)
    archive.append(le32(0x0605_4B50) + le16(0) + le16(0))
    archive.append(le16(UInt16(entries.count)) + le16(UInt16(entries.count)))
    archive.append(le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0))
    return archive
  }

  private func le16(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }
  private func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }
}

@Suite("Avatar archives")
struct AvatarArchiveTests {
  let processor = AvatarImageProcessor()

  /// A complete avatar, cut from a drawn sheet.
  func avatar() throws -> AvatarSpriteSet {
    let sprites = try SpriteSheetProcessor.sprites(
      fromSheet: try drawnSheet(columns: 5, rows: 2), expressions: AvatarExpression.allCases)
    return AvatarSpriteSet(
      manifest: AvatarManifest(
        name: "Blue", source: .generated, provider: "codex", description: "a blue bean"),
      sprites: sprites)
  }

  func sprite(side: Int = 256) throws -> Data {
    var image = RGBAImage(width: side, height: side)
    for y in (side / 4)..<(3 * side / 4) {
      for x in (side / 4)..<(3 * side / 4) {
        let offset = image.offset(x, y)
        image.pixels[offset] = 200
        image.pixels[offset + 3] = 255
      }
    }
    return try ImageCodec.png(image)
  }

  @Test("An exported avatar reads back the same, pixel for pixel")
  func roundTrip() throws {
    let original = try avatar()
    let (read, ignored) = try processor.avatar(fromArchive: processor.archive(original))

    #expect(ignored == 0)
    #expect(read.isComplete)
    #expect(read.manifest.name == "Blue")
    #expect(read.manifest.description == "a blue bean")
    #expect(read.manifest.source == .imported)
    for expression in AvatarExpression.allCases {
      let before = try ImageCodec.decode(#require(original.sprites[expression]))
      let after = try ImageCodec.decode(#require(read.sprites[expression]))
      #expect(before.pixels == after.pixels, "\(expression)")
    }
  }

  @Test("The default avatar reads, and holds every expression the animation shows")
  func defaultAvatar() throws {
    let avatar = try #require(DefaultAvatar.load())
    #expect(avatar.isComplete)
    #expect(avatar.manifest.source == .bundled)
  }

  @Test("The default avatar passes the whole import, as any archive would")
  func defaultAvatarImports() throws {
    let url = try #require(DefaultAvatar.archiveURL)
    let (avatar, ignored) = try processor.avatar(fromArchive: Data(contentsOf: url))
    #expect(avatar.isComplete)
    #expect(ignored == 0)
  }

  @Test("An archive without a manifest is read from the names of its images")
  func withoutManifest() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "neutral.png", contents: try sprite()),
      .init(name: "Pleased.PNG", contents: try sprite()),
    ])
    let (avatar, _) = try processor.avatar(fromArchive: zip.data())
    #expect(Set(avatar.sprites.keys) == [.neutral, .pleased])
    #expect(!avatar.isComplete)
    #expect(avatar.missingExpressions.count == 8)
  }

  @Test("One folder at the root is accepted; __MACOSX and .DS_Store are left out; others counted")
  func sharedRoot() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "Robot/neutral.png", contents: try sprite()),
      .init(name: "Robot/.DS_Store", contents: Data("x".utf8)),
      .init(name: "__MACOSX/Robot/._neutral.png", contents: Data("x".utf8)),
      .init(name: "Robot/notes.txt", contents: Data("x".utf8)),
    ])
    let (avatar, ignored) = try processor.avatar(fromArchive: zip.data())
    #expect(avatar.sprites.keys.contains(.neutral))
    #expect(ignored == 1)
  }

  @Test(
    "An entry that could land outside the folder is refused",
    arguments: ["../neutral.png", "/etc/neutral.png", "a/b/neutral.png", "a\\neutral.png"])
  func unsafeNames(_ name: String) throws {
    let zip = HandMadeZip(entries: [
      .init(name: name, contents: try sprite()), .init(name: "pleased.png", contents: try sprite()),
    ])
    #expect(throws: AvatarProblem.archiveUnsafeEntry(name)) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("A symbolic link is refused")
  func symbolicLink() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "neutral.png", contents: Data("/etc/passwd".utf8), mode: 0o120777)
    ])
    #expect(throws: AvatarProblem.archiveUnsafeEntry("neutral.png")) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An encrypted entry is refused")
  func encrypted() throws {
    let zip = HandMadeZip(entries: [.init(name: "neutral.png", contents: try sprite(), flags: 1)])
    #expect(throws: AvatarProblem.archiveEncrypted) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An entry declaring more than the bounds is refused before it is inflated")
  func zipBomb() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "neutral.png", contents: try sprite(), declaredSize: 200 * 1024 * 1024)
    ])
    #expect(throws: AvatarProblem.archiveTooLarge) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("Too many entries are refused")
  func tooManyEntries() throws {
    let zip = HandMadeZip(
      entries: (0..<70).map { .init(name: "file\($0).txt", contents: Data("x".utf8)) })
    #expect(throws: AvatarProblem.archiveTooLarge) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An archive of a later format is refused")
  func newerFormat() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "manifest.json", contents: Data(#"{"format": 99, "name": "Later"}"#.utf8)),
      .init(name: "neutral.png", contents: try sprite()),
    ])
    #expect(throws: AvatarProblem.archiveFromNewerVersion) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("Images of different sizes are refused")
  func differentSizes() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "neutral.png", contents: try sprite(side: 256)),
      .init(name: "pleased.png", contents: try sprite(side: 300)),
    ])
    #expect(throws: AvatarProblem.imagesOfDifferentSizes(.pleased)) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("Two images of one expression are refused")
  func duplicate() throws {
    let zip = HandMadeZip(entries: [
      .init(name: "neutral.png", contents: try sprite()),
      .init(name: "Neutral.PNG", contents: try sprite()),
    ])
    #expect(throws: AvatarProblem.duplicateExpression(.neutral)) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An image larger than an avatar needs is refused")
  func tooLargeDrawing() throws {
    let zip = HandMadeZip(entries: [.init(name: "neutral.png", contents: try sprite(side: 2_100))])
    #expect(throws: AvatarProblem.imageTooLarge) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An image too small is refused")
  func tooSmall() throws {
    let zip = HandMadeZip(entries: [.init(name: "neutral.png", contents: try sprite(side: 64))])
    #expect(throws: AvatarProblem.imageTooSmall(.neutral)) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("An archive with no image of an expression is refused")
  func noImage() throws {
    let zip = HandMadeZip(entries: [.init(name: "readme.txt", contents: Data("x".utf8))])
    #expect(throws: AvatarProblem.archiveHasNoImage) {
      try processor.avatar(fromArchive: zip.data())
    }
  }

  @Test("What is not a zip is refused")
  func notAZip() {
    #expect(throws: AvatarProblem.archiveUnreadable) {
      try processor.avatar(fromArchive: Data("hello".utf8))
    }
  }

  @Test("A damaged entry is refused by its checksum")
  func damaged() throws {
    var data = HandMadeZip(entries: [.init(name: "neutral.png", contents: try sprite())]).data()
    // In the image, past the entry's local header.
    data[120] ^= 0xFF
    #expect(throws: AvatarProblem.self) {
      try processor.avatar(fromArchive: data)
    }
  }

  @Test("Leaving the description out of an export")
  func withoutDescription() throws {
    let workshop = AvatarWorkshop(processing: processor)
    let data = try workshop.exportArchive(try avatar(), includingDescription: false)
    let (read, _) = try processor.avatar(fromArchive: data)
    #expect(read.manifest.description == nil)
    #expect(read.manifest.name == "Blue")
  }
}

@Suite("The avatar kept on disk")
struct FileAvatarStoreTests {
  func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "avatar-store-\(UUID().uuidString)", isDirectory: true
    ).appendingPathComponent("Avatar", isDirectory: true)
  }

  func avatar() throws -> AvatarSpriteSet {
    try #require(DefaultAvatar.load())
  }

  @Test("Nothing kept is the default avatar")
  func nothingKept() async throws {
    let store = FileAvatarStore(directory: temporaryDirectory())
    #expect(try await store.load() == nil)
  }

  @Test("A saved avatar reads back, and replacing it leaves no staging folder behind")
  func saveAndReplace() async throws {
    let directory = temporaryDirectory()
    let store = FileAvatarStore(directory: directory)
    var first = try avatar()
    first.manifest.name = "First"
    try await store.save(first)
    var second = first
    second.manifest.name = "Second"
    try await store.save(second)

    #expect(try await store.load()?.manifest.name == "Second")
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: directory.deletingLastPathComponent().path)
    #expect(siblings == ["Avatar"])
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
    #expect(mode as? Int == 0o700)
  }

  @Test("Removing it goes back to the default")
  func remove() async throws {
    let store = FileAvatarStore(directory: temporaryDirectory())
    try await store.save(try avatar())
    try await store.remove()
    #expect(try await store.load() == nil)
  }

  @Test("A kept avatar missing an expression says which, and is not used")
  func incomplete() async throws {
    let directory = temporaryDirectory()
    let store = FileAvatarStore(directory: directory)
    try await store.save(try avatar())
    try FileManager.default.removeItem(at: directory.appendingPathComponent("thinking.png"))
    await #expect(throws: AvatarStoreError.incomplete([.thinking])) {
      try await store.load()
    }
  }

  @Test("A damaged file is not trusted for being in the application's folder")
  func damaged() async throws {
    let directory = temporaryDirectory()
    let store = FileAvatarStore(directory: directory)
    try await store.save(try avatar())
    try Data("not a png".utf8).write(to: directory.appendingPathComponent("neutral.png"))
    await #expect(throws: AvatarStoreError.unreadable) {
      try await store.load()
    }
  }
}
