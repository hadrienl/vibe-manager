import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VibeApplication

@testable import VibePersistence

/// Answers Google's addresses, and counts them.
private final class FakeGoogle: @unchecked Sendable {
  private let lock = NSLock()
  private var asked = 0
  let answer: @Sendable (URL) throws -> (Data, Int)

  init(_ answer: @escaping @Sendable (URL) throws -> (Data, Int)) {
    self.answer = answer
  }

  var count: Int { lock.withLock { asked } }

  var fetch: GoogleThemeFonts.Fetch {
    { url in
      self.lock.withLock { self.asked += 1 }
      return try self.answer(url)
    }
  }

  static var offline: FakeGoogle { FakeGoogle { _ in throw URLError(.notConnectedToInternet) } }
}

private let font =
  (try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Apple Braille.ttf")))
  ?? Data()

/// The family the test faces stand for: every one is Apple Braille, which CoreText names so.
private func standing(for family: String) -> GoogleThemeFonts.FaceFamilies {
  { GoogleThemeFonts.isFont($0) ? [family] : [] }
}

private let css = """
  @font-face { font-family: 'Zz Test'; font-style: normal; font-weight: 400;
    src: url(https://fonts.gstatic.com/s/zz/v1/regular.ttf) format('truetype'); }
  """

/// A PNG of a few pixels, not all one colour.
private func png() -> Data {
  let context = CGContext(
    data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
  context.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.4, alpha: 1))
  context.fillEllipse(in: CGRect(x: 16, y: 10, width: 32, height: 20))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(
    data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

private func zip(_ files: [(String, Data)]) -> Data {
  ZipArchiveWriter.archive(files.map { DiagnosticFile(name: $0.0, contents: $0.1) })
}

@Suite("Importing a theme's archive (#361)")
struct ThemeImportTests {
  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-import-\(UUID().uuidString)", isDirectory: true)

  /// A library of its own folder — another Mac's, or this one's.
  private func library(_ name: String, google: FakeGoogle = .offline)
    -> FileConversationThemeLibrary
  {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    return FileConversationThemeLibrary(
      directory: folder,
      fonts: GoogleThemeFonts(
        directory: folder.appendingPathComponent("Fonts"), fetch: google.fetch,
        faceFamilies: standing(for: "Zz Test")),
      images: FileThemeImageStore(directory: folder.appendingPathComponent("Images")))
  }

  private func files(in name: String) -> [String] {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
  }

  @Test("An export imported elsewhere is the same theme: colours, fonts, layout and picture")
  func roundTrip() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (font, 200)
    }
    let there = library("there", google: google)
    let images = FileThemeImageStore(
      directory: root.appendingPathComponent("there/Images", isDirectory: true))
    var theme = ConversationThemeLibraryRules.kept(.night, name: "Aurore")
    theme.fonts.message = "Zz Test"
    theme.backdrop.image = try await images.keep(png())
    theme.backdrop.veil = 0.7
    _ = await GoogleThemeFonts(
      directory: root.appendingPathComponent("there/Fonts"), fetch: google.fetch
    ).prepare("Zz Test")
    let saved = try await there.save(theme, name: "Aurore")
    let archive = try await there.archive(saved.id, preview: nil)

    let here = library("here")
    let imported = try await here.importArchive(archive)
    #expect(imported.missingFonts.isEmpty)
    #expect(imported.theme.id != saved.id)
    #expect(imported.theme.isPersonal)
    #expect(imported.theme.personalName == "Aurore")
    #expect(imported.theme.colors == saved.colors)
    #expect(imported.theme.fonts == saved.fonts)
    #expect(imported.theme.layout == saved.layout)
    #expect(imported.theme.backdrop.veil == 0.7)
    let picture = try #require(imported.theme.backdrop.image)
    #expect(ConversationThemeFile.isImageName(picture))
    // Read back by the library, with its picture found here.
    let reloaded = try #require(await here.load().themes.first)
    #expect(reloaded.id == imported.theme.id)
    #expect(reloaded.backdrop.localImage != nil)
    // The font came from the archive: this Mac never asked Google.
    #expect(files(in: "here/Fonts") == ["Zz Test"])
  }

  @Test("A theme that cannot be written leaves neither its picture nor its fonts")
  func couldNotWrite() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var theme = ConversationTheme.named("Aurore", from: .night)
    theme.fonts.message = "Zz Test"
    let archive = zip([
      ("theme.json", ConversationThemeFile.encode(theme)), ("backdrop.jpg", png()),
      ("fonts/Zz Test/0.ttf", font),
    ])
    let here = library("here")
    // The pictures can be written, the themes cannot.
    let folder = root.appendingPathComponent("here", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("Images"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    await #expect(throws: ThemeImportError.couldNotWrite) { try await here.importArchive(archive) }
    #expect(files(in: "here") == ["Images"])
    #expect(files(in: "here/Images").isEmpty)
  }

  @Test("A name taken gets a number, and the same archive twice is two themes")
  func uniqueName() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = zip([("theme.json", ConversationThemeFile.encode(.named("Aurore", from: .night)))]
    )
    let here = library("here")
    let first = try await here.importArchive(archive)
    let second = try await here.importArchive(archive)
    #expect(first.theme.personalName == "Aurore")
    #expect(second.theme.personalName == "Aurore 2")
    #expect(first.theme.id != second.theme.id)
  }

  @Test("A folder at the root, as the Finder makes when a folder is compressed, is accepted")
  func sharedRoot() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = zip([
      ("Aurore/theme.json", ConversationThemeFile.encode(.named("Aurore", from: .night))),
      ("Aurore/preview.png", png()),
    ])
    #expect(try await library("here").importArchive(archive).theme.personalName == "Aurore")
  }

  @Test(
    "What is not a theme is refused, and nothing is written",
    arguments: [
      ("not a zip", Data("hello".utf8), ThemeImportError.notATheme),
      ("no theme file", zip([("preview.png", png())]), .notATheme),
      ("not JSON", zip([("theme.json", Data("{".utf8))]), .file(.notJSON)),
      (
        "a later format", zip([("theme.json", Data(#"{"format": 99}"#.utf8))]),
        .file(.unknownFormat)
      ),
      ("an entry out of the folder", zip([("../theme.json", Data("{}".utf8))]), .notATheme),
      (
        "too deep", zip([("a/b/c/d/theme.json", Data("{}".utf8)), ("x", Data())]), .notATheme
      ),
    ])
  func refused(_ label: String, _ archive: Data, _ error: ThemeImportError) async {
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: error) { try await library("here").importArchive(archive) }
    #expect(files(in: "here").isEmpty)
  }

  @Test("Colours that cannot be read on each other are refused")
  func illegible() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: ConversationThemeFile.encode(.named("Gris", from: .night))) as? [String: Any])
    var colors = try #require(object["colors"] as? [String: Any])
    colors["text"] = colors["background"]
    object["colors"] = colors
    let archive = zip([("theme.json", try JSONSerialization.data(withJSONObject: object))])
    await #expect {
      try await library("here").importArchive(archive)
    } throws: { error in
      guard case ThemeImportError.file(.illegible) = error else { return false }
      return true
    }
    #expect(files(in: "here").isEmpty)
  }

  @Test("An archive too large is refused before anything is read")
  func tooLarge() async {
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = Data(count: 31 * 1024 * 1024)
    await #expect(throws: ThemeImportError.tooLarge) {
      try await library("here").importArchive(archive)
    }
  }

  @Test("Without its picture, or with one that is not, a theme is imported without it")
  func withoutPicture() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var theme = ConversationTheme.named("Aurore", from: .night)
    theme.backdrop.image = String(repeating: "a", count: 64) + ".jpg"
    let file = ConversationThemeFile.encode(theme)
    let missing = try await library("here").importArchive(zip([("theme.json", file)]))
    #expect(missing.theme.backdrop.image == nil)
    let broken = try await library("here").importArchive(
      zip([("theme.json", file), ("backdrop.jpg", Data("not a picture".utf8))]))
    #expect(broken.theme.backdrop.image == nil)
  }

  @Test("A font absent from the archive is fetched; one found nowhere is said, the theme kept")
  func absentFonts() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var theme = ConversationTheme.named("Aurore", from: .night)
    theme.fonts.message = "Zz Test"
    let archive = zip([("theme.json", ConversationThemeFile.encode(theme))])

    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (font, 200)
    }
    let fetched = try await library("online", google: google).importArchive(archive)
    #expect(fetched.missingFonts.isEmpty)
    #expect(google.count > 0)

    let offline = try await library("offline").importArchive(archive)
    #expect(offline.missingFonts == ["Zz Test"])
    #expect(offline.theme.fonts.message == "Zz Test")
  }

  @Test("A face of the archive that is not a font is not kept")
  func notAFont() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    var theme = ConversationTheme.named("Aurore", from: .night)
    theme.fonts.code = "Zz Test"
    let archive = zip([
      ("theme.json", ConversationThemeFile.encode(theme)),
      ("fonts/Zz Test/0.ttf", Data("<html>".utf8)),
    ])
    let imported = try await library("here").importArchive(archive)
    #expect(imported.missingFonts == ["Zz Test"])
    #expect(!files(in: "here/Fonts").contains("Zz Test"))
  }
}

@Suite("An export carries its fonts as far as it can (#361)")
struct ThemeExportFontsTests {
  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-export-\(UUID().uuidString)", isDirectory: true)

  @Test("A family never fetched is fetched for the export once, held in memory and never kept")
  func fetchedForTheExport() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    // Installed here or not, what Google serves is not kept: kept, it would be activated over
    // the family installed at the next launch.
    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (font, 200)
    }
    let fonts = GoogleThemeFonts(
      directory: root.appendingPathComponent("Fonts"), fetch: google.fetch)
    let exported = await fonts.exportedFaces(of: "Zz Test")
    #expect(exported.map(\.name) == ["0.ttf"])
    #expect(exported.first?.contents == font)
    let asked = google.count
    #expect(await fonts.exportedFaces(of: "Zz Test").map(\.contents) == [font])
    #expect(google.count == asked)
    #expect(await fonts.files(of: "Zz Test").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Fonts").path))
  }

  @Test("A family that comes with macOS is not asked about; one Google does not serve, once")
  func notCarried() async {
    defer { try? FileManager.default.removeItem(at: root) }
    let unknown = FakeGoogle { _ in (Data("Bad Request".utf8), 400) }
    let fonts = GoogleThemeFonts(
      directory: root.appendingPathComponent("Fonts"), fetch: unknown.fetch)
    #expect(await fonts.exportedFaces(of: "Menlo").isEmpty)
    #expect(await fonts.exportedFaces(of: "SF Mono").isEmpty)
    #expect(unknown.count == 0)
    #expect(await fonts.exportedFaces(of: "Zz Nowhere Sans").isEmpty)
    let asked = unknown.count
    #expect(asked > 0)
    #expect(await fonts.exportedFaces(of: "Zz Nowhere Sans").isEmpty)
    #expect(unknown.count == asked)
    let away = GoogleThemeFonts(
      directory: root.appendingPathComponent("Away"), fetch: FakeGoogle.offline.fetch)
    #expect(await away.exportedFaces(of: "Zz Nowhere Sans").isEmpty)
  }

  @Test("Faces of another family than the one declared are not kept")
  func anotherFamily() async {
    defer { try? FileManager.default.removeItem(at: root) }
    // As CoreText reads them: these faces are Apple Braille's.
    let fonts = GoogleThemeFonts(
      directory: root.appendingPathComponent("Fonts"), fetch: FakeGoogle.offline.fetch)
    #expect(!(await fonts.install("Zz Carried", faces: [font])))
    #expect(await fonts.files(of: "Zz Carried").isEmpty)
  }

  @Test("A family kept is not drawn under another case: CoreText's names are exact")
  func otherCase() async {
    defer { try? FileManager.default.removeItem(at: root) }
    let fonts = GoogleThemeFonts(
      directory: root.appendingPathComponent("Fonts"), fetch: FakeGoogle.offline.fetch,
      faceFamilies: standing(for: "Zz Carried"))
    #expect(await fonts.install("Zz Carried", faces: [font]))
    #expect(await fonts.prepare("zz carried") != .available)
    #expect(!(await fonts.install("zz carried", faces: [font])))
  }

  @Test("Faces carried by an archive are kept once, and not over a family already here")
  func install() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Fonts")
    let fonts = GoogleThemeFonts(
      directory: folder, fetch: FakeGoogle.offline.fetch,
      faceFamilies: standing(for: "Zz Carried"))
    #expect(await fonts.install("Zz Carried", faces: [font, Data("x".utf8)]))
    #expect(await fonts.files(of: "Zz Carried").count == 1)
    #expect(await fonts.install("Zz Carried", faces: [font, font]))
    #expect(await fonts.files(of: "Zz Carried").count == 1)
    #expect(await fonts.install("Menlo", faces: [font]))
    #expect(await fonts.files(of: "Menlo").isEmpty)
    #expect(!(await fonts.install("Zz Nothing", faces: [Data("x".utf8)])))
    #expect(!(await fonts.install("../etc", faces: [font])))
  }
}

extension ConversationTheme {
  /// A built-in theme as a personal one named `name`, as a file of the library holds it.
  fileprivate static func named(_ name: String, from theme: ConversationTheme)
    -> ConversationTheme
  {
    ConversationThemeLibraryRules.kept(theme, name: name)
  }
}
