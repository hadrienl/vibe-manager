import AppKit
import Foundation
import UniformTypeIdentifiers
import VibeApplication

/// One element of a drop, as read from the pasteboard (#42).
enum DroppedItem: Equatable, Sendable {
  /// A file or a folder on disk. `isTemporary` when it lives in a temporary folder that will not
  /// outlive the drop — a floating screenshot — and has to be kept.
  case file(URL, isTemporary: Bool)
  /// An image with no file of its own: dragged out of a web page, copied bytes.
  case data(Data, suggestedName: String)
  /// A file received for the drop — a promise kept by Mail or Photos — staged where it will be
  /// deleted once kept.
  case staged(URL, suggestedName: String)
  /// Selected text, or a web address.
  case text(String)
}

/// Reads what was dropped, in the order it was dropped (#42).
///
/// Each element is looked at on its own: a file first, then an image, then a web address, then
/// text, then any file the source promises. An image dragged out of Safari carries both its bytes
/// and its address: the bytes are kept, because an agent reads an image from a file and not from
/// an address.
enum DropReader {
  /// Everything is looked at, and what cannot be read is left out.
  static let acceptedTypes: [UTType] = [.item]

  /// The items of the drop, in the order of the drop. `failed` counts the elements that offered
  /// something this reader could not load; a tab of the web view is left out without counting.
  @MainActor
  static func read(_ providers: [NSItemProvider]) async -> (items: [DroppedItem], failed: Int) {
    // Loaded together, put back in order: each provider answers when it wants to, and the order
    // of the drop is the order the paths are typed in.
    let boxes = providers.map(UncheckedProvider.init)
    let results = await withTaskGroup(of: (Int, Reading).self) { group in
      for (index, box) in boxes.enumerated() {
        group.addTask { (index, await reading(from: box.provider)) }
      }
      var results = [Reading](repeating: .ignored, count: boxes.count)
      for await (index, reading) in group { results[index] = reading }
      return results
    }
    var items: [DroppedItem] = []
    var failed = 0
    for result in results {
      switch result {
      case .item(let item): items.append(item)
      case .unreadable: failed += 1
      case .ignored: break
      }
    }
    return (items, failed)
  }

  /// What one element of the drop turned out to be.
  private enum Reading: Sendable {
    case item(DroppedItem)
    /// Nothing to type, and nothing that went wrong either.
    case ignored
    case unreadable
  }

  private static func reading(from provider: NSItemProvider) async -> Reading {
    guard let item = await read(provider) else { return .unreadable }
    // A tab of the web view moved along its strip and let go here: nothing to type, and nothing
    // to warn about. Read as an address as well as text, since its prefix looks like a scheme.
    if case .text(let text) = item, BrowserTabDrag.tabID(in: text) != nil { return .ignored }
    return .item(item)
  }

  private static func read(_ provider: NSItemProvider) async -> DroppedItem? {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      let url = await loadURL(provider), url.isFileURL
    {
      return .file(url, isTemporary: isTemporary(url))
    }
    // Asked for `.item`, SwiftUI hands a file of the disk over under its own type, opened in
    // place, and no longer as a file URL (#131).
    if let url = await loadFileInPlace(provider) {
      return .file(url, isTemporary: isTemporary(url))
    }
    if let image = types.first(where: { $0.conforms(to: .image) }),
      let data = await loadData(provider, type: image)
    {
      return imageItem(data, type: image, suggestedName: provider.suggestedName)
    }
    if provider.canLoadObject(ofClass: URL.self), let url = await loadURL(provider) {
      return .text(url.absoluteString)
    }
    if provider.canLoadObject(ofClass: String.self), let text = await loadString(provider) {
      return .text(text)
    }
    if let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .directory) }),
      let staged = await stage(provider, type: type)
    {
      return .staged(staged, suggestedName: provider.suggestedName ?? staged.lastPathComponent)
    }
    return nil
  }

  /// Formats the agents read are kept; any other — the TIFF AppKit hands a copied image in, the
  /// HEIC of a photo — becomes a PNG: Claude Code and Codex read PNG, JPEG, GIF and WebP only.
  static func imageItem(_ data: Data, type: UTType, suggestedName: String?) -> DroppedItem {
    var data = data
    var type = type
    let readable: [UTType] = [.png, .jpeg, .gif, .webP]
    if !readable.contains(where: type.conforms(to:)), let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:])
    {
      data = png
      type = .png
    }
    let fileExtension = type.preferredFilenameExtension ?? "png"
    let stem = suggestedName.map { ($0 as NSString).deletingPathExtension } ?? ""
    let name =
      stem.isEmpty
      ? DropNaming.timestampName(at: Date(), fileExtension: fileExtension)
      : "\(stem).\(fileExtension)"
    return .data(data, suggestedName: name)
  }

  /// Whether a dropped file lives in a folder the system empties behind the drop: the temporary
  /// folders of `/var/folders`, where a floating screenshot is kept while it is dragged. Resolved
  /// first, which takes `/private` off a path that exists.
  static func isTemporary(_ url: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().path
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    return path.hasPrefix(temporary) || path.hasPrefix("/var/folders/")
      || path.hasPrefix("/private/var/folders/")
  }

  private static func loadURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
    }
  }

  private static func loadFileInPlace(_ provider: NSItemProvider) async -> URL? {
    guard let type = provider.registeredContentTypesForOpenInPlace.first else { return nil }
    return await withCheckedContinuation { continuation in
      _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) {
        url, isInPlace, _ in
        continuation.resume(returning: isInPlace ? url : nil)
      }
    }
  }

  private static func loadString(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: String.self) { text, _ in
        continuation.resume(returning: text)
      }
    }
  }

  private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  /// The file a promise delivers is deleted as soon as the handler returns: it is moved out
  /// before, into a folder of its own under the temporary directory.
  private static func stage(_ provider: NSItemProvider, type: UTType) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: nil)
          return
        }
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent("VibeManagerDrops", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
          try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          try FileManager.default.copyItem(at: url, to: destination)
          continuation.resume(returning: destination)
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }
}

/// `NSItemProvider` is not `Sendable`, and the task that loads one is the only one to touch it.
private struct UncheckedProvider: @unchecked Sendable {
  let provider: NSItemProvider
  init(_ provider: NSItemProvider) { self.provider = provider }
}
