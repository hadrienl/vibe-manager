import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VibeApplication

/// The pictures behind personal themes (#118), in `Themes/Images/`:
///
/// ```
/// Themes/Images/          0700
///   <sha256>.jpg          0600, the picture decoded, at most 2560 points wide, encoded again
/// ```
///
/// A picture is kept under the digest of what was written: the same picture twice is one file,
/// and two themes can share one. Nothing is kept as it arrived — a picture is decoded by ImageIO,
/// within bounds, then encoded again without its metadata — and an address is only ever https.
public struct FileThemeImageStore: ThemeImageStoring {
  public typealias Fetch = GoogleThemeFonts.Fetch

  /// More than any photograph a theme needs; less than what would cost anything to read.
  static let maximumDownload = 25 * 1024 * 1024
  /// The longest side of a picture kept: a Retina display's width.
  static let maximumSide = 2560
  /// Beyond this many pixels, a picture is not decoded at all.
  static let maximumPixels = 120_000_000

  private let directory: URL
  private let fetchData: Fetch
  private let diagnostics: Diagnostics

  public init(
    directory: URL, diagnostics: Diagnostics = .disabled,
    fetch: @escaping Fetch = FileThemeImageStore.urlSession
  ) {
    self.directory = directory
    self.diagnostics = diagnostics
    self.fetchData = fetch
  }

  /// Reads the answer as it comes, and stops past `maximumDownload`: a link to a file of several
  /// gigabytes is refused before it fills the memory.
  public static let urlSession: Fetch = { url in
    let request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    // A redirection elsewhere than https is not followed into: the final address is checked.
    guard response.url?.scheme?.lowercased() == "https" else { return (Data(), 0) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { return (Data(), status) }
    guard response.expectedContentLength <= Int64(maximumDownload) else {
      throw ThemeImageError.tooLarge
    }
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > maximumDownload { throw ThemeImageError.tooLarge }
    }
    return (data, status)
  }

  public func fetch(_ url: URL) async throws -> String {
    guard ConversationThemeFile.isImageURL(url.absoluteString) else {
      throw ThemeImageError.unreachable
    }
    let data: Data
    do {
      let (body, status) = try await fetchData(url)
      guard status == 200, !body.isEmpty else { throw ThemeImageError.unreachable }
      data = body
    } catch ThemeImageError.tooLarge {
      diagnostics.record(.store, .notice, "theme.imageTooLarge")
      throw ThemeImageError.tooLarge
    } catch let error as ThemeImageError {
      diagnostics.record(.store, .notice, "theme.imageUnreachable")
      throw error
    } catch {
      diagnostics.record(.store, .notice, "theme.imageUnreachable")
      throw ThemeImageError.unreachable
    }
    let name = try keepData(data)
    diagnostics.record(.store, .info, "theme.imageFetched", ["size": .bytes(data.count)])
    return name
  }

  public func keep(_ data: Data) async throws -> String {
    let name = try keepData(data)
    diagnostics.record(.store, .info, "theme.imageDrawn", ["size": .bytes(data.count)])
    return name
  }

  public func location(of name: String) -> URL? {
    guard ConversationThemeFile.isImageName(name) else { return nil }
    let url = directory.appendingPathComponent(name, isDirectory: false)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private func keepData(_ data: Data) throws -> String {
    guard data.count <= Self.maximumDownload else { throw ThemeImageError.tooLarge }
    let encoded = try Self.reencoded(data)
    let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    let name = "\(digest).jpg"
    let target = directory.appendingPathComponent(name, isDirectory: false)
    if FileManager.default.fileExists(atPath: target.path) { return name }
    let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard
        FileManager.default.createFile(
          atPath: staging.path, contents: encoded, attributes: [.posixPermissions: 0o600]),
        rename(staging.path, target.path) == 0
      else { throw ThemeImageError.couldNotWrite }
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw ThemeImageError.couldNotWrite
    }
    return name
  }

  /// The picture decoded within bounds, at most `maximumSide` on its longest side, encoded again
  /// as a JPEG without metadata.
  static func reencoded(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw ThemeImageError.notAnImage }
    guard width * height <= maximumPixels else { throw ThemeImageError.tooLarge }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maximumSide),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw ThemeImageError.notAnImage
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ThemeImageError.couldNotWrite }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ThemeImageError.couldNotWrite }
    return output as Data
  }
}
