import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

/// Answers the addresses asked, and keeps them.
private final class FakeGoogle: @unchecked Sendable {
  private let lock = NSLock()
  private var asked: [URL] = []
  let answer: @Sendable (URL) throws -> (Data, Int)

  init(_ answer: @escaping @Sendable (URL) throws -> (Data, Int)) {
    self.answer = answer
  }

  var urls: [URL] { lock.withLock { asked } }

  var fetch: GoogleThemeFonts.Fetch {
    { url in
      self.lock.withLock { self.asked.append(url) }
      return try self.answer(url)
    }
  }
}

private let font =
  (try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Apple Braille.ttf")))
  ?? Data()

private let css = """
  @font-face { font-family: 'Zz Test'; font-style: normal; font-weight: 400;
    src: url(https://fonts.gstatic.com/s/zz/v1/regular.ttf) format('truetype'); }
  @font-face { font-family: 'Zz Test'; font-style: normal; font-weight: 700;
    src: url(https://fonts.gstatic.com/s/zz/v1/bold.ttf) format('truetype'); }
  @font-face { src: url(https://evil.example/x.ttf); }
  @font-face { src: url(http://fonts.gstatic.com/s/zz/v1/plain.ttf); }
  """

@Suite("The fonts of Google Fonts a theme asks for (#118)")
struct GoogleThemeFontsTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-fonts-\(UUID().uuidString)", isDirectory: true)

  @Test("Only the files of Google's own host, over https, are fetched")
  func fileURLs() {
    let urls = GoogleThemeFonts.fileURLs(in: css)
    #expect(urls.map(\.lastPathComponent) == ["regular.ttf", "bold.ttf"])
  }

  @Test("A family every Mac has is ready without asking anything")
  func installed() async {
    let google = FakeGoogle { _ in throw URLError(.notConnectedToInternet) }
    let fonts = GoogleThemeFonts(directory: directory, fetch: google.fetch)
    #expect(await fonts.prepare("Menlo") == .available)
    #expect(await fonts.prepare("New York") == .available)
    #expect(google.urls.isEmpty)
  }

  @Test("A family Google does not know is unknown; Google out of reach is not")
  func unknownAndUnreachable() async {
    let unknown = FakeGoogle { _ in (Data("Bad Request".utf8), 400) }
    let fonts = GoogleThemeFonts(directory: directory, fetch: unknown.fetch)
    #expect(await fonts.prepare("Zz Nowhere Sans") == .unknown)
    #expect(unknown.urls.count == 2)
    #expect(
      unknown.urls.first?.absoluteString.contains("family=Zz+Nowhere+Sans:ital,wght@") == true)
    #expect(unknown.urls.allSatisfy { $0.host == "fonts.googleapis.com" })

    let offline = FakeGoogle { _ in throw URLError(.notConnectedToInternet) }
    let away = GoogleThemeFonts(directory: directory, fetch: offline.fetch)
    #expect(await away.prepare("Zz Nowhere Sans") == .unreachable)
    #expect(await away.prepare("../../etc") == .unknown)
  }

  @Test("A family is fetched once, kept, activated, and given to an export")
  func download() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (font, 200)
    }
    let fonts = GoogleThemeFonts(directory: directory, fetch: google.fetch)
    #expect(await fonts.prepare("Zz Test") == .available)
    #expect(google.urls.count == 3)
    let files = await fonts.files(of: "Zz Test")
    #expect(files.count == 2)
    #expect(
      files.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "Zz Test" })
    #expect(await fonts.prepare("Zz Test") == .available)
    #expect(google.urls.count == 3)

    // Another instance finds it on disk, without Google.
    let offline = FakeGoogle { _ in throw URLError(.notConnectedToInternet) }
    let later = GoogleThemeFonts(directory: directory, fetch: offline.fetch)
    await later.activateAll()
    #expect(await later.prepare("Zz Test") == .available)
    #expect(offline.urls.isEmpty)
  }

  @Test("A file that is not a font is not kept")
  func notAFont() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (Data("<html>".utf8), 200)
    }
    let fonts = GoogleThemeFonts(directory: directory, fetch: google.fetch)
    #expect(await fonts.prepare("Zz Test") == .unreachable)
    #expect(await fonts.files(of: "Zz Test").isEmpty)
  }

  @Test("An export carries the families its theme fetched")
  func export() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-themes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let google = FakeGoogle { url in
      url.host == "fonts.googleapis.com" ? (Data(css.utf8), 200) : (font, 200)
    }
    let fonts = GoogleThemeFonts(
      directory: root.appendingPathComponent("Fonts"), fetch: google.fetch)
    #expect(await fonts.prepare("Zz Test") == .available)
    let library = FileConversationThemeLibrary(directory: root, fonts: fonts)
    var theme = ConversationThemeLibraryRules.kept(.night, name: "Avec police")
    theme.fonts.message = "Zz Test"
    let saved = try await library.save(theme, name: "Avec police")
    let archive = try await library.archive(saved.id, preview: nil)
    let text = String(decoding: archive, as: UTF8.self)
    #expect(text.contains("theme.json"))
    #expect(text.contains("fonts/Zz Test/0.ttf"))
    #expect(text.contains("fonts/Zz Test/1.ttf"))
    // The folder of fonts is not a theme, nor a problem.
    let contents = await library.load()
    #expect(contents.themes.map(\.id) == [saved.id])
    #expect(contents.problems.isEmpty)
  }
}

/// The real Google Fonts, over the network: opt in with `VIBE_THEME_INTEGRATION=1`.
@Suite(
  "Fonts fetched from the real Google Fonts",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_THEME_INTEGRATION"] == "1"))
struct GoogleThemeFontsIntegrationTests {
  @Test("A family of Google Fonts is fetched and activated; one made up is unknown")
  func google() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-fonts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fonts = GoogleThemeFonts(directory: directory)
    #expect(await fonts.prepare("Lobster") == .available)
    #expect(GoogleThemeFonts.isInstalled("Lobster"))
    #expect(await fonts.prepare("Zz Made Up Family") == .unknown)
  }
}
