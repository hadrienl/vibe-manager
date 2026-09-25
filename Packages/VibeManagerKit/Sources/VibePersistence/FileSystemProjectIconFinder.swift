import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VibeApplication
import VibeDomain

/// Looks for a project's icon in a closed list of places, and turns the one it keeps into a PNG
/// of at most 256 × 256 (#27).
///
/// The places come in three tiers, and the first tier that yields a usable image wins, with the
/// largest of its images:
///
/// 1. An application icon: the `AppIcon.appiconset` of an asset catalogue, or an `.icns`.
/// 2. A favicon — `favicon.svg`, `.png`, `.ico` — at the root, then in `public/`, `static/`,
///    `assets/`, `app/` and `src/app/`.
/// 3. `icon.png`, `icon.svg`, `logo.svg`, `logo.png`, in the same places.
///
/// Bounded so that the sheet never waits on it: three levels deep, 300 entries listed, files of at
/// most 2 MiB, 300 ms in all. Symbolic links are not followed, so the walk can neither loop nor
/// leave the project, and the folders that hold dependencies or build products are skipped.
public struct FileSystemProjectIconFinder: ProjectIconFinding {
  public static let maximumDepth = 3
  public static let maximumEntries = 300
  public static let maximumFileSize = 2 * 1024 * 1024
  public static let outputSize = 256

  static let skippedDirectories: Set<String> = [
    "node_modules", "DerivedData", "Pods", "vendor", "dist", "build", "Carthage",
  ]
  static let skippedExtensions: Set<String> = [
    "xcodeproj", "xcworkspace", "app", "framework", "bundle", "xcframework",
  ]
  static let webFolders = ["", "public", "static", "assets", "app", "src/app"]
  static let faviconNames = ["favicon.svg", "favicon.png", "favicon.ico"]
  static let genericNames = ["icon.png", "icon.svg", "logo.svg", "logo.png"]

  private let timeLimit: Duration

  public init(timeLimit: Duration = .milliseconds(300)) {
    self.timeLimit = timeLimit
  }

  public func icon(inFolder path: String) async -> ProjectIcon? {
    let timeLimit = timeLimit
    return await Task.detached(priority: .userInitiated) {
      let deadline = ContinuousClock.now.advanced(by: timeLimit)
      let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
      let files = Self.walk(root, until: deadline)
      for tier in Self.tiers(of: files) {
        // The largest first, and the next one when it cannot be read.
        for candidate in tier.sorted(by: { $0.rank > $1.rank }) {
          guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
          if let icon = ProjectIconImporter.icon(from: candidate.url) { return icon }
        }
      }
      return nil
    }.value
  }

  /// A file found by the walk, and where it sits relative to the project.
  struct Entry: Equatable {
    let url: URL
    let relativePath: String
    let size: Int

    var name: String { url.lastPathComponent }
    var folder: String {
      let parent = (relativePath as NSString).deletingLastPathComponent
      return parent
    }
  }

  struct Candidate {
    let url: URL
    /// The larger the better: an image's pixel width, a vector format counting as the largest.
    let rank: Int
  }

  /// Every file within reach, breadth first, so that the root is read before anything deeper.
  static func walk(_ root: URL, until deadline: ContinuousClock.Instant) -> [Entry] {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    var files: [Entry] = []
    var listed = 0
    var queue: [(url: URL, relative: String, depth: Int)] = [(root, "", 0)]
    while !queue.isEmpty, listed < maximumEntries, ContinuousClock.now < deadline {
      let (directory, relative, depth) = queue.removeFirst()
      guard
        let children = try? manager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
      else { continue }
      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard listed < maximumEntries else { break }
        listed += 1
        guard let values = try? child.resourceValues(forKeys: Set(keys)),
          values.isSymbolicLink != true
        else { continue }
        let name = child.lastPathComponent
        let path = relative.isEmpty ? name : "\(relative)/\(name)"
        if values.isDirectory == true {
          let pathExtension = child.pathExtension.lowercased()
          if pathExtension == "xcassets" {
            // An asset catalogue is looked into for its application icon alone, at any depth
            // the walk reached it: that is where an Xcode project keeps its icon.
            let set = child.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
            queue.insert((set, "\(path)/AppIcon.appiconset", maximumDepth), at: 0)
          } else if depth + 1 < maximumDepth, !skippedDirectories.contains(name),
            !skippedExtensions.contains(pathExtension)
          {
            queue.append((child, path, depth + 1))
          }
        } else if let size = values.fileSize, size > 0, size <= maximumFileSize {
          files.append(Entry(url: child, relativePath: path, size: size))
        }
      }
    }
    return files
  }

  /// The candidates of each tier, best tier first.
  static func tiers(of files: [Entry]) -> [[Candidate]] {
    let applicationIcons = files.compactMap { entry -> Candidate? in
      let lowered = entry.name.lowercased()
      if lowered.hasSuffix(".icns") {
        return Candidate(url: entry.url, rank: 1_024)
      }
      if entry.folder.hasSuffix("AppIcon.appiconset"), lowered.hasSuffix(".png") {
        return Candidate(url: entry.url, rank: ProjectIconImporter.pixelWidth(of: entry.url))
      }
      return nil
    }
    func named(_ names: [String]) -> [Candidate] {
      files.compactMap { entry -> Candidate? in
        guard webFolders.contains(entry.folder), names.contains(entry.name.lowercased())
        else { return nil }
        let rank =
          entry.name.lowercased().hasSuffix(".svg")
          ? 2_048 : ProjectIconImporter.pixelWidth(of: entry.url)
        return Candidate(url: entry.url, rank: rank)
      }
    }
    return [applicationIcons, named(faviconNames), named(genericNames)]
  }
}

/// Turns an image file into the PNG a session keeps: at most 256 pixels on its longer side,
/// centred on a transparent square, its aspect ratio preserved.
enum ProjectIconImporter {
  static func icon(from url: URL) -> ProjectIcon? {
    guard let data = try? Data(contentsOf: url),
      data.count <= FileSystemProjectIconFinder.maximumFileSize,
      let image = image(from: data, isVector: url.pathExtension.lowercased() == "svg")
    else { return nil }
    // A detailed icon can outweigh what the store keeps at 256 pixels; half the size keeps it.
    for side in [FileSystemProjectIconFinder.outputSize, 128] {
      guard let png = png(of: image, side: side) else { return nil }
      if png.count <= FileSessionIconStore.byteLimit {
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        guard let id = SessionIconID(sha256: digest) else { return nil }
        return ProjectIcon(id: id, pngData: png)
      }
    }
    return nil
  }

  /// The width of the largest image a file holds, without decoding it; 0 when unreadable.
  static func pixelWidth(of url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
    var widest = 0
    for index in 0..<CGImageSourceGetCount(source) {
      let properties =
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
      widest = max(widest, properties[kCGImagePropertyPixelWidth] as? Int ?? 0)
    }
    return widest
  }

  private static func image(from data: Data, isVector: Bool) -> CGImage? {
    if isVector {
      guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
        return nil
      }
      let side = CGFloat(FileSystemProjectIconFinder.outputSize)
      let scale = side / max(image.size.width, image.size.height)
      var rect = CGRect(
        x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
      return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    // An `.ico` or an `.icns` holds several sizes: the largest one is the one to scale down.
    var best = 0
    var bestWidth = 0
    for index in 0..<CGImageSourceGetCount(source) {
      let properties =
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
      let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
      if width > bestWidth {
        best = index
        bestWidth = width
      }
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: FileSystemProjectIconFinder.outputSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary)
  }

  private static func png(of image: CGImage, side: Int) -> Data? {
    guard image.width > 0, image.height > 0,
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // A small favicon is scaled up to fill the square: a badge the size of a 16-pixel image
    // would say nothing.
    let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(
        x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width,
        height: height))
    guard let rendered = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
