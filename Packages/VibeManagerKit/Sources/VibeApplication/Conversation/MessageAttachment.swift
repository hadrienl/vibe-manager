import Foundation
import UniformTypeIdentifiers
import VibeDomain

/// A file that came with a prompt, as the conversation shows it (#209).
///
/// Only a description: the decoder neither reads a file nor decodes an image. What is heavy — a
/// thumbnail, a duration, a page count — is worked out when the attachment is shown.
public struct MessageAttachment: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case image, audio, video, pdf, text, other
  }

  public enum Source: Hashable, Sendable {
    /// A file on disk.
    case file(URL)
    /// An image held only by the transcript: pasted from the clipboard.
    case embedded(EmbeddedImage)
    /// A file on disk, and the copy the transcript holds of it, shown when the file is gone.
    case fileWithEmbedded(URL, EmbeddedImage)
    /// The CLI says an image was there, but neither its file nor its bytes can be found.
    case missing
  }

  /// Stable across readings of the same transcript: the entry's identifier and the rank.
  public let id: String
  public var kind: Kind
  public var source: Source
  /// The file's name; nil for an image pasted without one, which the view names by its rank.
  public var name: String?

  public init(id: String, kind: Kind, source: Source, name: String?) {
    self.id = id
    self.kind = kind
    self.source = source
    self.name = name
  }

  public var file: URL? {
    switch source {
    case .file(let url), .fileWithEmbedded(let url, _): return url
    case .embedded, .missing: return nil
    }
  }

  public var embeddedImage: EmbeddedImage? {
    switch source {
    case .embedded(let image), .fileWithEmbedded(_, let image): return image
    case .file, .missing: return nil
    }
  }

  /// A file joined by its path.
  public static func file(_ url: URL, id: String) -> MessageAttachment {
    MessageAttachment(
      id: id, kind: kind(forExtension: url.pathExtension), source: .file(url),
      name: url.lastPathComponent)
  }

  /// What a file is, from its extension.
  public static func kind(forExtension pathExtension: String) -> Kind {
    guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
      return .other
    }
    return kind(for: type)
  }

  /// What a block of a transcript holds, from its media type: `image/png`.
  public static func kind(forMediaType mediaType: String) -> Kind {
    guard let type = UTType(mimeType: mediaType) else { return .other }
    return kind(for: type)
  }

  public static func kind(for type: UTType) -> Kind {
    if type.conforms(to: .pdf) { return .pdf }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .audio) { return .audio }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
    if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
    return .other
  }
}

/// Where an image held by a transcript can be read again (#209): never its bytes. A conversation
/// of fifty screenshots holds fifty of these, not fifty images.
public struct EmbeddedImage: Hashable, Sendable {
  /// The line of the transcript that holds the image.
  public var line: TranscriptLineLocation
  /// The keys that lead, from the line's object, to the array of blocks the image is one of:
  /// `["message", "content"]`.
  public var container: [String]
  /// The image's block in that array.
  public var index: Int
  public var mediaType: String
  /// The length of its base64: an estimate of its size, and a check that the line read again is
  /// still the one decoded.
  public var encodedLength: Int

  public init(
    line: TranscriptLineLocation, container: [String], index: Int, mediaType: String,
    encodedLength: Int
  ) {
    self.line = line
    self.container = container
    self.index = index
    self.mediaType = mediaType
    self.encodedLength = encodedLength
  }

  /// The size of the image, worked out from its base64.
  public var estimatedByteCount: Int { encodedLength / 4 * 3 }

  /// The base64 of the image a block holds, and its media type: Claude Code's
  /// `{"source": {"data", "media_type"}}`, or a `data:` URL — Codex's `image_url`.
  public static func encodedImage(in block: [String: Any]) -> (base64: String, mediaType: String)? {
    if let source = block["source"] as? [String: Any], let data = source["data"] as? String {
      return (data, source["media_type"] as? String ?? "image/png")
    }
    let url =
      block["image_url"] as? String ?? (block["image_url"] as? [String: Any])?["url"] as? String
      ?? block["url"] as? String
    guard let url, url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
    let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
    guard header.hasSuffix(";base64") else { return nil }
    return (String(url[url.index(after: comma)...]), String(header.dropLast(7)))
  }

  /// The base64 of this image, read again from its line: nil when the line no longer holds it —
  /// the transcript was rewritten.
  public func readBase64() -> String? {
    guard let handle = try? FileHandle(forReadingFrom: line.file) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: line.offset)) != nil,
      let data = try? handle.read(upToCount: line.length), data.count == line.length,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    var node: Any? = object
    for key in container { node = (node as? [String: Any])?[key] }
    guard let blocks = node as? [[String: Any]], blocks.indices.contains(index),
      let image = Self.encodedImage(in: blocks[index]),
      (image.base64 as NSString).length == encodedLength
    else { return nil }
    return image.base64
  }
}

/// Where a line of a transcript is in its file.
public struct TranscriptLineLocation: Hashable, Sendable {
  public var file: URL
  public var offset: UInt64
  public var length: Int

  public init(file: URL, offset: UInt64, length: Int) {
    self.file = file
    self.offset = offset
    self.length = length
  }
}

/// The files the composer joined to a prompt by their paths (#209).
///
/// The composer writes them at the end of the message, escaped as Terminal.app writes a dropped
/// file, separated by spaces (`PromptEncoding`). The agent reads them as text: the message keeps
/// them, and only its display shows them as attachments. A path in the middle of a sentence stays
/// text.
public enum AttachedPaths {
  /// The text shown, without the paths at its end, and the files they name.
  public static func split(_ text: String) -> (text: String, files: [URL]) {
    guard let found = ShellPath.trailingPaths(in: text) else { return (text, []) }
    let body = found.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return (body, found.paths.map { URL(fileURLWithPath: $0) })
  }

  /// The text shown for a prompt: what `split` leaves.
  public static func displayText(_ text: String) -> String {
    split(text).text
  }
}

/// What may be done with a file a transcript names (#209, ADR 0025): it is shown, previewed,
/// revealed — never run. Opening an application, a script or a `.command` with its default
/// application would run it.
public enum AttachmentOpening {
  /// Whether the file can be handed to its default application: a document of a kind known to
  /// be read, never anything that launches — a program, a script, a `.fileloc` or `.webloc`, an
  /// installer, a profile. Links and aliases are followed; a folder or a package is never opened.
  public static func canOpen(_ url: URL) -> Bool {
    guard let type = harmlessType(of: url) else { return false }
    return documentTypes.contains { type.conforms(to: $0) }
  }

  /// Whether Quick Look may show it: anything that does not launch — Quick Look offers to open
  /// what it shows.
  public static func canPreview(_ url: URL) -> Bool {
    harmlessType(of: url) != nil
  }

  /// The type of the file a link or an alias leads to, unless it is a folder, a package or
  /// something that launches.
  private static func harmlessType(of url: URL) -> UTType? {
    guard url.isFileURL else { return nil }
    let resolved = (try? URL(resolvingAliasFileAt: url)) ?? url.resolvingSymlinksInPath()
    guard
      let values = try? resolved.resourceValues(forKeys: [
        .contentTypeKey, .isDirectoryKey, .isPackageKey,
      ]),
      values.isDirectory != true, values.isPackage != true, let type = values.contentType
    else { return nil }
    let refused: [UTType] = [.executable, .script, .package, .directory, .internetLocation]
    let refusedIdentifiers = [
      "com.apple.installer-package-archive", "com.apple.mobileconfig",
      "com.apple.shortcut", "com.sun.java-web-start", "com.microsoft.internet-shortcut",
    ]
    if refused.contains(where: { type.conforms(to: $0) })
      || refusedIdentifiers.contains(where: { identifier in
        UTType(identifier).map { type.conforms(to: $0) } ?? false
      })
    {
      return nil
    }
    return type
  }

  /// What is opened: read by its application, never run.
  private static let documentTypes: [UTType] = [
    .image, .pdf, .audiovisualContent, .plainText, .sourceCode, .json, .xml, .yaml, .rtf,
    .commaSeparatedText, .spreadsheet, .presentation,
    UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
    UTType("org.oasis-open.opendocument.text"), UTType("com.apple.iwork.pages.sffpages"),
  ].compactMap { $0 }

  /// Whether the session's web view can show it: a page `LinkRouting` would open, or an image.
  public static func canShowInWebView(_ url: URL) -> Bool {
    if LinkRouting.isPage(url) { return true }
    guard url.isFileURL,
      ToolCall.imageExtensions.contains(url.pathExtension.lowercased()),
      let type = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey])
        .contentType
    else { return false }
    return type.conforms(to: .image)
  }
}
