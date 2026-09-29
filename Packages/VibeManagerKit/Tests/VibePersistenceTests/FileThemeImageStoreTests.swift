import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VibeApplication

@testable import VibePersistence

/// A PNG of `width` by `height`, a gradient so that it is not all one colour.
private func png(width: Int, height: Int) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.2, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(srgbRed: 0.8, green: 0.9, blue: 0.7, alpha: 1))
  context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(
    data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

private func size(of data: Data) -> (Int, Int)? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = properties[kCGImagePropertyPixelWidth] as? Int,
    let height = properties[kCGImagePropertyPixelHeight] as? Int
  else { return nil }
  return (width, height)
}

@Suite("The pictures behind personal themes (#118)")
struct FileThemeImageStoreTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("vibe-images-\(UUID().uuidString)", isDirectory: true)

  @Test("A picture is encoded again, bounded, and named after its bytes")
  func keep() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileThemeImageStore(directory: directory)
    let name = try await store.keep(png(width: 4000, height: 2500))
    #expect(ConversationThemeFile.isImageName(name))
    #expect(name.hasSuffix(".jpg"))
    let url = try #require(store.location(of: name))
    let kept = try Data(contentsOf: url)
    let dimensions = try #require(size(of: kept))
    #expect(dimensions.0 == 2560)
    #expect(dimensions.1 == 1600)
    #expect(try await store.keep(png(width: 4000, height: 2500)) == name)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    #expect(permissions as? Int == 0o600)
    #expect(store.location(of: "../../etc/passwd") == nil)
  }

  @Test("What is not a picture is not kept")
  func notAPicture() async {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileThemeImageStore(directory: directory)
    await #expect(throws: ThemeImageError.notAnImage) {
      try await store.keep(Data("<html>not a picture</html>".utf8))
    }
  }

  @Test("Only an https address is fetched, and only what answers 200")
  func fetch() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let picture = png(width: 800, height: 500)
    let store = FileThemeImageStore(directory: directory) { url in
      url.path == "/forest.png" ? (picture, 200) : (Data(), 404)
    }
    let name = try await store.fetch(URL(string: "https://example.com/forest.png")!)
    #expect(store.location(of: name) != nil)
    await #expect(throws: ThemeImageError.unreachable) {
      try await store.fetch(URL(string: "https://example.com/missing.png")!)
    }
    await #expect(throws: ThemeImageError.unreachable) {
      try await store.fetch(URL(string: "http://example.com/forest.png")!)
    }
    await #expect(throws: ThemeImageError.unreachable) {
      try await store.fetch(URL(fileURLWithPath: "/etc/hosts"))
    }
    let huge = FileThemeImageStore(directory: directory) { _ in
      (Data(count: FileThemeImageStore.maximumDownload + 1), 200)
    }
    await #expect(throws: ThemeImageError.tooLarge) {
      try await huge.fetch(URL(string: "https://example.com/huge.png")!)
    }
  }

  @Test("A theme read finds its picture, and its export carries it")
  func library() async throws {
    let root = directory
    defer { try? FileManager.default.removeItem(at: root) }
    let images = FileThemeImageStore(directory: root.appendingPathComponent("Images"))
    let library = FileConversationThemeLibrary(directory: root, images: images)
    let name = try await images.keep(png(width: 640, height: 400))
    var theme = ConversationThemeLibraryRules.kept(.night, name: "Forêt")
    theme.backdrop.image = name
    theme.backdrop.imagePrompt = "pines"
    let saved = try await library.save(theme, name: "Forêt")
    let read = try #require(await library.load().themes.first)
    #expect(read.backdrop.image == name)
    #expect(read.backdrop.localImage?.lastPathComponent == name)
    let archive = try await library.archive(saved.id, preview: nil)
    #expect(String(decoding: archive, as: UTF8.self).contains("backdrop.jpg"))
    // The picture gone, the theme is still there, without it.
    try FileManager.default.removeItem(at: root.appendingPathComponent("Images"))
    let alone = try #require(await library.load().themes.first)
    #expect(alone.backdrop.localImage == nil)
  }
}
