import AVFoundation
import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import VibeApplication

/// What is shown of an attachment, worked out off the main actor (#209).
struct AttachmentPreview: @unchecked Sendable {
  /// A thumbnail, never the image at full size. `CGImage` is immutable: shared freely.
  var thumbnail: CGImage?
  /// The first lines of a text file.
  var lines: String?
  /// Of a sound or a film, in seconds.
  var duration: Double?
  var pageCount: Int?
  var byteCount: Int?
  /// The file is not there any more, and the transcript holds no copy of it.
  var isMissing = false

  static let missing = AttachmentPreview(isMissing: true)

  /// What the cache counts it for: the thumbnail's pixels.
  var cost: Int { thumbnail.map { $0.bytesPerRow * $0.height } ?? 256 }
}

/// Thumbnails and facts of the attachments shown, read in the background and kept in a bounded
/// cache (#209). An image held by a transcript is read again from its line and decoded only to its
/// thumbnail's size: a conversation of many screenshots never holds them whole.
actor AttachmentPreviews {
  static let shared = AttachmentPreviews()

  /// Lines of a text file shown, and the bytes read for them at most.
  static let textLineCount = 6
  static let textByteLimit = 4 * 1_024

  private let cache = NSCache<NSString, Entry>()
  private var loading: [String: Task<AttachmentPreview, Never>] = [:]
  private let temporaryFolder: URL
  private var temporaryFiles: [String: URL] = [:]

  private final class Entry {
    let preview: AttachmentPreview
    init(_ preview: AttachmentPreview) { self.preview = preview }
  }

  init(temporaryFolder: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeAttachments", isDirectory: true))
  {
    cache.totalCostLimit = 64 << 20
    self.temporaryFolder = temporaryFolder
    // Copies left by a run that ended without removing them.
    try? FileManager.default.removeItem(at: temporaryFolder)
  }

  /// The preview of `attachment` with a thumbnail of `maxPixel` pixels at most on its longer side.
  func preview(for attachment: MessageAttachment, maxPixel: Int) async -> AttachmentPreview {
    let key = Self.key(attachment.source, maxPixel: maxPixel)
    if let entry = cache.object(forKey: key as NSString) { return entry.preview }
    if let task = loading[key] { return await task.value }
    let task = Task.detached(priority: .utility) {
      await Self.load(attachment, maxPixel: maxPixel)
    }
    loading[key] = task
    let preview = await task.value
    loading[key] = nil
    cache.setObject(Entry(preview), forKey: key as NSString, cost: preview.cost)
    return preview
  }

  /// A file Quick Look can show for `attachment`: its own, or a copy of the image the transcript
  /// holds, written for the preview and removed by `discardTemporaryFiles`. Nil when neither is
  /// there.
  func previewableFile(for attachment: MessageAttachment) -> URL? {
    if let file = attachment.file, FileManager.default.fileExists(atPath: file.path) {
      return file
    }
    guard let image = attachment.embeddedImage else { return nil }
    let key = Self.key(.embedded(image), maxPixel: 0)
    if let file = temporaryFiles[key], FileManager.default.fileExists(atPath: file.path) {
      return file
    }
    guard let data = Self.decoded(image) else { return nil }
    let name =
      attachment.name
      ?? "Image \(temporaryFiles.count + 1)."
      + (UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "png")
    let folder = temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = folder.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: file)
    } catch {
      return nil
    }
    temporaryFiles[key] = file
    return file
  }

  /// Removes the copies written for Quick Look.
  func discardTemporaryFiles() {
    for file in temporaryFiles.values {
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
    temporaryFiles = [:]
  }

  /// The image a transcript holds, decoded at full size: for Copy only.
  nonisolated func imageData(_ image: EmbeddedImage) -> Data? {
    Self.decoded(image)
  }

  // MARK: - Loading

  static func key(_ source: MessageAttachment.Source, maxPixel: Int) -> String {
    let name: String
    switch source {
    case .file(let url): name = "file:\(url.path)"
    case .embedded(let image): name = embeddedKey(image)
    case .fileWithEmbedded(let url, let image): name = "file:\(url.path)|\(embeddedKey(image))"
    case .missing: name = "missing"
    }
    return "\(name)@\(maxPixel)"
  }

  private static func embeddedKey(_ image: EmbeddedImage) -> String {
    "embedded:\(image.line.file.path):\(image.line.offset):\(image.index)"
  }

  static func load(_ attachment: MessageAttachment, maxPixel: Int) async -> AttachmentPreview {
    if let file = attachment.file, FileManager.default.fileExists(atPath: file.path) {
      return await load(file: file, kind: attachment.kind, maxPixel: maxPixel)
    }
    if let image = attachment.embeddedImage {
      guard let data = decoded(image) else { return .missing }
      return autoreleasepool {
        var preview = AttachmentPreview(byteCount: data.count)
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
          preview.thumbnail = thumbnail(of: source, maxPixel: maxPixel)
        }
        return preview
      }
    }
    return .missing
  }

  private static func load(file: URL, kind: MessageAttachment.Kind, maxPixel: Int) async
    -> AttachmentPreview
  {
    var preview = AttachmentPreview()
    preview.byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    switch kind {
    case .image:
      preview.thumbnail = autoreleasepool {
        CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { thumbnail(of: $0, maxPixel: maxPixel) }
      }
      if preview.thumbnail == nil { preview.thumbnail = await quickLookThumbnail(file, maxPixel) }
    case .pdf:
      preview.pageCount = CGPDFDocument(file as CFURL)?.numberOfPages
      preview.thumbnail = await quickLookThumbnail(file, maxPixel)
    case .video:
      preview.thumbnail = await quickLookThumbnail(file, maxPixel)
      preview.duration = await duration(of: file)
    case .audio:
      preview.duration = await duration(of: file)
    case .text:
      preview.lines = firstLines(of: file)
    case .other:
      break
    }
    return preview
  }

  static func decoded(_ image: EmbeddedImage) -> Data? {
    autoreleasepool {
      image.readBase64().flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }
  }

  /// Decoded to `maxPixel` at most, never at full size; turned the way the image says.
  static func thumbnail(of source: CGImageSource, maxPixel: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func quickLookThumbnail(_ file: URL, _ maxPixel: Int) async -> CGImage? {
    let request = QLThumbnailGenerator.Request(
      fileAt: file, size: CGSize(width: maxPixel, height: maxPixel), scale: 1,
      representationTypes: .thumbnail)
    return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
  }

  private static func duration(of file: URL) async -> Double? {
    guard let duration = try? await AVURLAsset(url: file).load(.duration),
      duration.isNumeric
    else { return nil }
    return duration.seconds
  }

  /// The first lines of a text file, from its first bytes only, whatever its encoding.
  static func firstLines(of file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: textByteLimit) else { return nil }
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(textLineCount).joined(separator: "\n")
  }
}
