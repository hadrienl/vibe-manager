import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

/// A PNG of `side` pixels, of one colour.
private func png(side: Int, red: CGFloat = 0.2) throws -> Data {
  let context = try #require(
    CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(red: red, green: 0.4, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))
  let image = try #require(context.makeImage())
  return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

private let svg = Data(
  """
  <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
    <rect width="64" height="64" fill="#0b63e5"/>
  </svg>
  """.utf8)

@Suite("Finding a project's icon")
struct ProjectIconFinderTests {
  private let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeIcons-\(UUID().uuidString)/My Project", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private func write(_ data: Data, at path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  private func find(timeLimit: Duration = .seconds(5)) async -> ProjectIcon? {
    await FileSystemProjectIconFinder(timeLimit: timeLimit).icon(inFolder: root.path)
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  @Test(
    "Each place of the list is found, in a folder whose name has spaces",
    arguments: [
      "favicon.png", "public/favicon.png", "static/favicon.png", "assets/favicon.png",
      "app/favicon.png", "src/app/favicon.png", "icon.png", "public/logo.png",
      "App/Assets.xcassets/AppIcon.appiconset/icon-512.png", "Resources/App.icns",
    ])
  func everyPlace(path: String) async throws {
    defer { cleanUp() }
    try write(try png(side: 64), at: path)

    let icon = try #require(await find())

    #expect(icon.pngData.count <= FileSessionIconStore.byteLimit)
    let image = try #require(NSBitmapImageRep(data: icon.pngData))
    #expect(image.pixelsWide == 256)
    #expect(image.pixelsHigh == 256)
  }

  @Test("A vector icon is rendered")
  func svgIsRendered() async throws {
    defer { cleanUp() }
    try write(svg, at: "app/icon.svg")

    #expect(await find() != nil)
  }

  @Test("An application icon wins over a favicon, which wins over a logo")
  func tiersAreOrdered() async throws {
    defer { cleanUp() }
    try write(try png(side: 32, red: 0.1), at: "logo.png")
    try write(try png(side: 32, red: 0.5), at: "public/favicon.png")
    let favicon = try #require(await find())
    try write(try png(side: 32, red: 0.9), at: "Mac/Assets.xcassets/AppIcon.appiconset/a.png")

    let appIcon = try #require(await find())

    #expect(appIcon != favicon)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Mac"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("public"))
    let logo = try #require(await find())
    #expect(logo != favicon)
  }

  @Test("Within a tier, the largest image is kept")
  func largestInTheTier() async throws {
    defer { cleanUp() }
    let set = "Assets.xcassets/AppIcon.appiconset"
    try write(try png(side: 16, red: 0.1), at: "\(set)/small.png")
    try write(try png(side: 512, red: 0.9), at: "\(set)/large.png")
    try FileManager.default.removeItem(at: root.appendingPathComponent("\(set)/small.png"))
    let large = try #require(await find())
    try write(try png(side: 16, red: 0.1), at: "\(set)/small.png")

    #expect(await find() == large)
  }

  @Test("Folders of dependencies and hidden folders are not searched")
  func skippedFolders() async throws {
    defer { cleanUp() }
    try write(try png(side: 32), at: "node_modules/public/favicon.png")
    try write(try png(side: 32), at: ".git/favicon.png")
    try write(try png(side: 32), at: "build/favicon.png")

    #expect(await find() == nil)
  }

  @Test("Nothing deeper than three levels is read")
  func depthIsBounded() async throws {
    defer { cleanUp() }
    try write(try png(side: 32), at: "a/b/c/d/Resources.icns")

    #expect(await find() == nil)
  }

  @Test("No more than 300 entries are listed")
  func entriesAreBounded() async throws {
    defer { cleanUp() }
    for index in 0..<FileSystemProjectIconFinder.maximumEntries {
      try write(Data("x".utf8), at: String(format: "a-%04d.txt", index))
    }
    try write(try png(side: 32), at: "public/favicon.png")

    #expect(await find() == nil)
  }

  @Test("A symbolic link is not followed, and cannot make the walk loop")
  func linksAreNotFollowed() async throws {
    defer { cleanUp() }
    let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try png(side: 32).write(to: outside.appendingPathComponent("favicon.png"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("public"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("loop"), withDestinationURL: root)

    #expect(await find() == nil)
  }

  @Test("An asset catalogue's icon set that is a link is not followed")
  func appIconSetLinkIsNotFollowed() async throws {
    defer { cleanUp() }
    let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try png(side: 32).write(to: outside.appendingPathComponent("icon.png"))
    let catalogue = root.appendingPathComponent("Assets.xcassets")
    try FileManager.default.createDirectory(at: catalogue, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: catalogue.appendingPathComponent("AppIcon.appiconset"), withDestinationURL: outside)

    #expect(await find() == nil)
  }

  @Test("A cancelled search answers at once")
  func cancellationAnswers() async throws {
    defer { cleanUp() }
    try write(try png(side: 32), at: "favicon.png")
    let finder = FileSystemProjectIconFinder(timeLimit: .seconds(600))
    let search = Task { [root] in await finder.icon(inFolder: root.path) }
    search.cancel()

    let started = ContinuousClock.now
    _ = await search.value
    // Far from the time limit rather than close to zero: a loaded CI runner can stall every test
    // for seconds, and what matters is that the cancellation, not the limit, ended the wait.
    #expect(ContinuousClock.now - started < .seconds(60))
  }

  @Test("A file too large to be an icon is ignored")
  func sizeIsBounded() async throws {
    defer { cleanUp() }
    try write(Data(count: FileSystemProjectIconFinder.maximumFileSize + 1), at: "favicon.png")

    #expect(await find() == nil)
  }

  @Test("A corrupt image, an invalid SVG and an unknown format give nothing, without error")
  func unreadableFiles() async throws {
    defer { cleanUp() }
    try write(Data("not a png".utf8), at: "favicon.png")
    try write(Data("<svg".utf8), at: "public/favicon.svg")
    try write(Data("GIF89a".utf8), at: "static/favicon.ico")

    #expect(await find() == nil)
  }

  @Test("A search out of time answers nothing")
  func deadlineIsBounded() async throws {
    defer { cleanUp() }
    try write(try png(side: 32), at: "favicon.png")

    #expect(await find(timeLimit: .zero) == nil)
  }

  @Test("The same icon is always the same file")
  func contentAddressed() async throws {
    defer { cleanUp() }
    try write(try png(side: 64), at: "favicon.png")

    let first = await find()
    let second = await find()

    #expect(first != nil)
    #expect(first == second)
  }
}

@Suite("Keeping the icons of the sessions")
struct FileSessionIconStoreTests {
  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeIconStore-\(UUID().uuidString)/Icons", isDirectory: true)
  }

  @Test("An icon is written once, owner only, and outlives its source")
  func writtenOnce() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let source = directory.deletingLastPathComponent().appendingPathComponent("favicon.png")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png(side: 64).write(to: source)
    let icon = try #require(ProjectIconImporter.icon(from: source))
    let store = FileSessionIconStore(directory: directory)

    try await store.save(icon)
    let url = store.fileURL(for: icon.id)
    let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
    try await store.save(icon)
    try FileManager.default.removeItem(at: source)

    #expect(await store.pngData(for: icon.id) == icon.pngData)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.modificationDate] as? Date == written as? Date)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
  }

  @Test("A missing file reads as no icon")
  func missingFile() async throws {
    let store = FileSessionIconStore(directory: makeDirectory())
    let id = try #require(SessionIconID(sha256: String(repeating: "a", count: 64)))

    #expect(await store.pngData(for: id) == nil)
  }

  @Test("Only a digest can name an icon file")
  func identifiersAreDigests() {
    #expect(SessionIconID(sha256: "../../etc/passwd") == nil)
    #expect(SessionIconID(sha256: String(repeating: "A", count: 64)) == nil)
    #expect(SessionIconID(sha256: String(repeating: "0", count: 64)) != nil)
  }
}

@Suite("Keeping the names given to groups")
struct FileFolderLabelStoreTests {
  private func makeURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeFolders-\(UUID().uuidString)/folders.json")
  }

  @Test("A name is kept, and an empty one gives the folder's back")
  func roundTrip() async throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let folder = SessionFolderKey(path: "/work/My Project")

    try await FileFolderLabelStore(url: url).setLabel("  Backend  ", for: folder)
    #expect(try await FileFolderLabelStore(url: url).labels() == [folder: "Backend"])

    try await FileFolderLabelStore(url: url).setLabel("", for: folder)
    #expect(try await FileFolderLabelStore(url: url).labels().isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  @Test("An unreadable document is never written over")
  func unreadableIsKept() async throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let store = FileFolderLabelStore(url: url)

    await #expect(throws: (any Error).self) {
      try await store.setLabel("Backend", for: SessionFolderKey(path: "/work/api"))
    }
    #expect(try Data(contentsOf: url) == Data("{ not json".utf8))
  }
}

@Suite("Keeping the project icon in the session store")
struct SessionStoreIconTests {
  private let v4Document = """
    {
      "schemaVersion": 4,
      "savedAt": "2026-09-21T10:00:00.000Z",
      "sessions": [
        {
          "id": "88E8C16B-2824-4CCC-8EF4-C7A1C16EA3AD",
          "name": "Stored in v4",
          "initialPrompt": "",
          "appearance": { "symbolName": "bolt", "colorHex": "#0B63E5" },
          "lifecycle": {
            "status": "closed",
            "createdAt": "2026-09-21T09:00:00.000Z",
            "updatedAt": "2026-09-21T10:00:00.000Z",
            "closedAt": "2026-09-21T10:00:00.000Z"
          },
          "repositories": [],
          "agentHistory": []
        }
      ]
    }
    """

  @Test("A v4 session is read without an icon, and rewritten")
  func v4IsMigrated() throws {
    let decoded = try SessionStoreCodec().decode(Data(v4Document.utf8))

    let session = try #require(decoded.sessions.first)
    #expect(session.appearance == SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5"))
    #expect(decoded.requiresRewrite)
  }

  @Test("An icon comes back as it was written")
  func iconRoundTrips() throws {
    let id = try #require(SessionIconID(sha256: String(repeating: "c", count: 64)))
    let session = WorkSession(
      name: "With icon",
      appearance: SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5", iconID: id))
    let codec = SessionStoreCodec()

    let decoded = try codec.decode(try codec.encode(sessions: [session]))

    #expect(decoded.sessions == [session])
    #expect(!decoded.requiresRewrite)
  }

  @Test("A v6 store keeps its task statuses, and is rewritten with room for icons")
  func v6IsMigrated() throws {
    let session = WorkSession(name: "Waiting", taskStatus: .waiting)
    let codec = SessionStoreCodec()
    let v6 = String(decoding: try codec.encode(sessions: [session]), as: UTF8.self)
      .replacingOccurrences(of: #""schemaVersion" : 7"#, with: #""schemaVersion" : 6"#)

    let decoded = try codec.decode(Data(v6.utf8))

    #expect(decoded.sessions == [session])
    #expect(decoded.requiresRewrite)
  }

  @Test("An icon that does not name a digest is dropped, and the session kept")
  func invalidIconIsDropped() throws {
    let document =
      v4Document
      .replacingOccurrences(of: "\"schemaVersion\": 4", with: "\"schemaVersion\": 7")
      .replacingOccurrences(
        of: "\"colorHex\": \"#0B63E5\" }",
        with: "\"colorHex\": \"#0B63E5\", \"iconID\": \"../../secrets\" }")

    let decoded = try SessionStoreCodec().decode(Data(document.utf8))

    #expect(decoded.sessions.first?.appearance.iconID == nil)
    #expect(decoded.sessions.first?.name == "Stored in v4")
  }
}
