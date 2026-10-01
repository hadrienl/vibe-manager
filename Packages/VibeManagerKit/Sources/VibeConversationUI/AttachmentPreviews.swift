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
  /// The file, when it is on disk: what the menu acts on.
  var existingFile: URL?
  /// Its icon in the Finder.
  var icon: NSImage?
  /// Whether its application may open it, and the web view show it: see `AttachmentOpening`.
  var canOpen = false
  var canShowInWebView = false

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

  /// Read from any thread: `NSCache` is.
  private nonisolated(unsafe) let cache = NSCache<NSString, Entry>()
  private var loading: [String: Task<AttachmentPreview?, Never>] = [:]
  /// Loads under way at once, at most `concurrentLoads`; the others wait their turn.
  private var running = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private let temporaryFolder: URL
  private var temporaryFiles: [String: URL] = [:]
  /// Loads started: for tests.
  private(set) var loadCount = 0

  /// Two at a time: scrolling fast past many screenshots never decodes them all at once, nor
  /// takes every thread the transcript's reading needs.
  static let concurrentLoads = 2

  private final class Entry {
    let preview: AttachmentPreview
    /// The file's date and size when it was read: a file changed or back is read again.
    let signature: FileSignature?
    init(_ preview: AttachmentPreview, signature: FileSignature?) {
      self.preview = preview
      self.signature = signature
    }
  }

  struct FileSignature: Equatable {
    var modified: Date?
    var size: Int?
  }

  init(temporaryFolder: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeAttachments", isDirectory: true))
  {
    cache.totalCostLimit = 64 << 20
    self.temporaryFolder = temporaryFolder
    // Copies left by a run that ended without removing them.
    try? FileManager.default.removeItem(at: temporaryFolder)
  }

  /// What the cache holds for `attachment`, at once and from any thread, without checking that
  /// its file is still the same: what a tile shows first, before `preview(for:maxPixel:)` says.
  nonisolated func cachedPreview(for attachment: MessageAttachment, maxPixel: Int)
    -> AttachmentPreview?
  {
    cache.object(forKey: Self.key(attachment.source, maxPixel: maxPixel) as NSString)?.preview
  }

  /// The preview of `attachment` with a thumbnail of `maxPixel` pixels at most on its longer side.
  /// Read again when its file changed; a file missing is never kept as such. When the caller is
  /// cancelled, so is the load it alone waited for, and what it gets is not to be shown.
  func preview(for attachment: MessageAttachment, maxPixel: Int) async -> AttachmentPreview {
    let key = Self.key(attachment.source, maxPixel: maxPixel)
    let signature = Self.signature(of: attachment.file)
    if let entry = cache.object(forKey: key as NSString), entry.signature == signature {
      return entry.preview
    }
    while !Task.isCancelled {
      let task = loading[key] ?? startLoading(attachment, maxPixel: maxPixel, key: key)
      let preview = await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
      if loading[key] == task { loading[key] = nil }
      guard let preview else { continue }
      if !preview.isMissing {
        cache.setObject(
          Entry(preview, signature: signature), forKey: key as NSString, cost: preview.cost)
      }
      return preview
    }
    return AttachmentPreview()
  }

  private func startLoading(_ attachment: MessageAttachment, maxPixel: Int, key: String)
    -> Task<AttachmentPreview?, Never>
  {
    let task = Task<AttachmentPreview?, Never> {
      await acquire()
      defer { release() }
      guard !Task.isCancelled else { return nil }
      return await Self.load(attachment, maxPixel: maxPixel)
    }
    loading[key] = task
    loadCount += 1
    return task
  }

  private func acquire() async {
    if running < Self.concurrentLoads {
      running += 1
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  private func release() {
    if waiting.isEmpty {
      running -= 1
    } else {
      waiting.removeFirst().resume()
    }
  }

  private static func signature(of file: URL?) -> FileSignature? {
    guard var file else { return nil }
    // A URL keeps the values it read: they are read again from the disk.
    file.removeAllCachedResourceValues()
    guard
      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return nil }
    return FileSignature(modified: values.contentModificationDate, size: values.fileSize)
  }

  /// A file Quick Look can show for `attachment`: its own, or a copy of the image the transcript
  /// holds, written for the preview and removed by `discardTemporaryFiles`. Nil when neither is
  /// there.
  /// - Parameter name: what the copy is called, as the message names the image: « Image 2 ».
  func previewableFile(for attachment: MessageAttachment, name: String) -> URL? {
    if let file = attachment.file, FileManager.default.fileExists(atPath: file.path) {
      // Quick Look offers to open what it shows: only a document goes to it (ADR 0025).
      return AttachmentOpening.canPreview(file) ? file : nil
    }
    guard let image = attachment.embeddedImage else { return nil }
    let key = Self.key(.embedded(image), maxPixel: 0)
    if let file = temporaryFiles[key], FileManager.default.fileExists(atPath: file.path) {
      return file
    }
    guard let data = Self.decoded(image) else { return nil }
    // Named after its media type, never after the transcript: a name it gives could make the copy
    // something Quick Look offers to run.
    let fileName =
      (name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      + "."
      + (UTType(mimeType: image.mediaType)?.conforms(to: .image) == true
        ? UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "png" : "png")
    let folder = temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = folder.appendingPathComponent(fileName)
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
    var file = file
    file.removeAllCachedResourceValues()
    preview.byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    preview.existingFile = file
    preview.icon = NSWorkspace.shared.icon(forFile: file.path)
    preview.canOpen = AttachmentOpening.canOpen(file)
    preview.canShowInWebView = AttachmentOpening.canShowInWebView(file)
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
