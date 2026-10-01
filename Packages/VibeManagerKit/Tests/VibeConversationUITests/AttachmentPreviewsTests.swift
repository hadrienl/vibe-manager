import AppKit
import Foundation
import Testing
import VibeApplication

@testable import VibeConversationUI

@Suite("What is shown of a joined file (#209)")
struct AttachmentPreviewsTests {
  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("previews-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A PNG of `width` × `height` pixels.
  private func png(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func previews() -> AttachmentPreviews {
    AttachmentPreviews(temporaryFolder: folder.appendingPathComponent("quicklook"))
  }

  @Test("An image file: a thumbnail no larger than asked, and its size")
  func imageFile() async throws {
    let file = folder.appendingPathComponent("wide.png")
    let data = try png(width: 1_600, height: 400)
    try data.write(to: file)
    let preview = await previews().preview(for: .file(file, id: "a"), maxPixel: 200)
    let thumbnail = try #require(preview.thumbnail)
    #expect(max(thumbnail.width, thumbnail.height) <= 200)
    #expect(thumbnail.width > thumbnail.height)
    #expect(preview.byteCount == data.count)
    #expect(!preview.isMissing)
  }

  @Test("An image held by the transcript only: read again from its line, to its thumbnail")
  func embeddedImage() async throws {
    let base64 = try png(width: 300, height: 300).base64EncodedString()
    let line = #"{"message":{"content":[{"type":"text","text":"[Image #1]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(base64)"}}]}}"#
    let transcript = folder.appendingPathComponent("t.jsonl")
    let prefix = #"{"first":true}"# + "\n"
    try Data((prefix + line + "\n").utf8).write(to: transcript)
    let image = EmbeddedImage(
      line: TranscriptLineLocation(
        file: transcript, offset: UInt64(prefix.utf8.count), length: line.utf8.count),
      container: ["message", "content"], index: 1, mediaType: "image/png",
      encodedLength: base64.utf8.count)
    let attachment = MessageAttachment(id: "e", kind: .image, source: .embedded(image), name: nil)
    let previews = previews()
    let preview = await previews.preview(for: attachment, maxPixel: 64)
    #expect(preview.thumbnail.map { max($0.width, $0.height) } == 64)

    // Quick Look is handed a copy, removed once it closes.
    let copy = try #require(await previews.previewableFile(for: attachment, name: "Image 1"))
    #expect(FileManager.default.fileExists(atPath: copy.path))
    #expect(copy.pathExtension == "png")
    await previews.discardTemporaryFiles()
    #expect(!FileManager.default.fileExists(atPath: copy.path))
  }

  @Test("A file gone, with no copy: missing, and nothing for Quick Look")
  func missingFile() async {
    let attachment = MessageAttachment.file(folder.appendingPathComponent("gone.txt"), id: "m")
    let previews = previews()
    #expect(await previews.preview(for: attachment, maxPixel: 64).isMissing)
    #expect(await previews.previewableFile(for: attachment, name: "Image 1") == nil)
  }

  @Test("A file gone whose copy the transcript holds is shown from the copy")
  func goneButEmbedded() async throws {
    let base64 = try png(width: 10, height: 10).base64EncodedString()
    let line = #"{"message":{"content":[{"type":"image","source":{"data":"\#(base64)"}}]}}"#
    let transcript = folder.appendingPathComponent("t2.jsonl")
    try Data((line + "\n").utf8).write(to: transcript)
    let image = EmbeddedImage(
      line: TranscriptLineLocation(file: transcript, offset: 0, length: line.utf8.count),
      container: ["message", "content"], index: 0, mediaType: "image/png",
      encodedLength: base64.utf8.count)
    let attachment = MessageAttachment(
      id: "g", kind: .image,
      source: .fileWithEmbedded(folder.appendingPathComponent("moved.png"), image), name: "moved.png")
    let preview = await previews().preview(for: attachment, maxPixel: 64)
    #expect(preview.thumbnail != nil)
    #expect(!preview.isMissing)
  }

  @Test("A text file: its first lines, from its first bytes only")
  func textFile() async throws {
    let file = folder.appendingPathComponent("notes.swift")
    let lines = (1...50).map { "line \($0)" }
    try Data(lines.joined(separator: "\n").utf8).write(to: file)
    let preview = await previews().preview(for: .file(file, id: "t"), maxPixel: 64)
    #expect(preview.lines == lines.prefix(AttachmentPreviews.textLineCount).joined(separator: "\n"))
  }

  @Test("Asked twice at once, read once; read again once the file changed")
  func cached() async throws {
    let file = folder.appendingPathComponent("once.txt")
    try Data("first".utf8).write(to: file)
    let previews = previews()
    let attachment = MessageAttachment.file(file, id: "o")
    async let first = previews.preview(for: attachment, maxPixel: 64)
    async let second = previews.preview(for: attachment, maxPixel: 64)
    #expect(await first.lines == "first")
    #expect(await second.lines == "first")
    #expect(await previews.preview(for: attachment, maxPixel: 64).lines == "first")
    #expect(await previews.loadCount == 1)
    #expect(previews.cachedPreview(for: attachment, maxPixel: 64)?.lines == "first")

    try Data("changed".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
    #expect(await previews.preview(for: attachment, maxPixel: 64).lines == "changed")
    #expect(await previews.loadCount == 2)
  }

  @Test("A file missing is not remembered as such: back, it is shown")
  func missingThenBack() async throws {
    let file = folder.appendingPathComponent("later.txt")
    let previews = previews()
    let attachment = MessageAttachment.file(file, id: "l")
    #expect(await previews.preview(for: attachment, maxPixel: 64).isMissing)
    try Data("here".utf8).write(to: file)
    #expect(await previews.preview(for: attachment, maxPixel: 64).lines == "here")
  }

  @Test("The copy for Quick Look is named as the message names the image, with its type")
  func copyName() async throws {
    let base64 = try png(width: 4, height: 4).base64EncodedString()
    let line = #"{"message":{"content":[{"type":"image","source":{"data":"\#(base64)"}}]}}"#
    let transcript = folder.appendingPathComponent("t3.jsonl")
    try Data((line + "\n").utf8).write(to: transcript)
    let image = EmbeddedImage(
      line: TranscriptLineLocation(file: transcript, offset: 0, length: line.utf8.count),
      container: ["message", "content"], index: 0, mediaType: "image/png",
      encodedLength: base64.utf8.count)
    let attachment = MessageAttachment(
      id: "n", kind: .image,
      source: .fileWithEmbedded(folder.appendingPathComponent("run.command"), image),
      name: "run.command")
    let copy = try #require(await previews().previewableFile(for: attachment, name: "run.command"))
    #expect(copy.lastPathComponent == "run.png")
  }

  @Test("The tile drawn for each kind of file, and for one gone")
  func styles() {
    let image = AttachmentPreview(thumbnail: Self.pixel)
    #expect(AttachmentTile.style(for: .image, preview: nil) == .loading)
    #expect(AttachmentTile.style(for: .image, preview: image) == .image)
    #expect(AttachmentTile.style(for: .image, preview: AttachmentPreview()) == .chip)
    #expect(AttachmentTile.style(for: .video, preview: image) == .video)
    #expect(AttachmentTile.style(for: .pdf, preview: image) == .pdf)
    #expect(AttachmentTile.style(for: .text, preview: AttachmentPreview(lines: "a")) == .text)
    #expect(AttachmentTile.style(for: .audio, preview: nil) == .audio)
    #expect(AttachmentTile.style(for: .other, preview: AttachmentPreview()) == .chip)
    #expect(AttachmentTile.style(for: .image, preview: .missing) == .missing)
    #expect(AttachmentTile.style(for: .audio, preview: .missing) == .missing)
  }

  static let pixel: CGImage = {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
  }()
}
