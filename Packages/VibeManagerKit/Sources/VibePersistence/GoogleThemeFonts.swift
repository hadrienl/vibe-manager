import CoreText
import Foundation
import VibeApplication

/// The fonts a personal theme asks for (#118): installed on the Mac, or a family of Google Fonts,
/// fetched once, kept beside the themes and activated for this application only — nothing is
/// installed for the rest of the system.
///
/// ```
/// Themes/Fonts/            0700
///   <Family>/<file>.ttf    0600, the regular, bold and italic faces Google serves
/// ```
///
/// Only two hosts are ever asked: `fonts.googleapis.com` for the style sheet that lists a
/// family's files, and `fonts.gstatic.com` for the files. A file that is not a font is not kept.
/// Google Fonts families are under the SIL Open Font License, which lets an exported theme carry
/// them.
public actor GoogleThemeFonts: ThemeFontResolving {
  /// Fetches an address: its body and its HTTP status. `URLSession` in the application.
  public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

  /// Families every Mac has under a name CoreText does not list as such.
  static let systemFamilies: Set<String> = ["SF Pro", "SF Mono", "New York"]
  /// No face of a family weighs more; a whole family is a few of them.
  static let maximumFileSize = 8 * 1024 * 1024
  static let maximumFiles = 8
  static let cssHost = "fonts.googleapis.com"
  static let fileHost = "fonts.gstatic.com"

  private let directory: URL
  private let fetch: Fetch
  private let diagnostics: Diagnostics
  private var registered: Set<String> = []

  public init(
    directory: URL, diagnostics: Diagnostics = .disabled,
    fetch: @escaping Fetch = GoogleThemeFonts.urlSession
  ) {
    self.directory = directory
    self.diagnostics = diagnostics
    self.fetch = fetch
  }

  public static let urlSession: Fetch = { url in
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    // No browser's name: Google then serves TrueType files, which CoreText reads.
    request.setValue("VibeManager", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  public func prepare(_ family: String) async -> FontAvailability {
    guard ConversationThemeFile.isFontFamily(family) else { return .unknown }
    if Self.isInstalled(family) { return .available }
    if activateKept(family) { return .available }
    return await download(family)
  }

  /// Activates every family fetched before: at launch, so that a theme draws with its fonts before
  /// the settings are ever opened.
  public func activateAll() {
    guard
      let folders = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }
    for folder in folders { _ = activateKept(folder.lastPathComponent) }
  }

  /// The files of a family fetched from Google Fonts, for an export. None for a family installed.
  public func files(of family: String) -> [URL] {
    guard ConversationThemeFile.isFontFamily(family) else { return [] }
    return fontFiles(in: folder(of: family))
  }

  // MARK: - Fetching

  private func download(_ family: String) async -> FontAvailability {
    let css: Data
    do {
      guard let found = try await styleSheet(of: family) else {
        diagnostics.record(.store, .notice, "theme.fontUnknown")
        return .unknown
      }
      css = found
    } catch {
      diagnostics.record(.store, .notice, "theme.fontUnreachable")
      return .unreachable
    }
    let urls = Self.fileURLs(in: String(decoding: css, as: UTF8.self))
    guard !urls.isEmpty else { return .unknown }
    let staging = directory.appendingPathComponent(
      ".staging-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    var bytes = 0
    do {
      try FileManager.default.createDirectory(
        at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for (index, url) in urls.enumerated() {
        let (data, status) = try await fetch(url)
        guard status == 200, data.count <= Self.maximumFileSize, Self.isFont(data) else {
          throw CocoaError(.fileReadCorruptFile)
        }
        bytes += data.count
        let file = staging.appendingPathComponent("\(index).ttf")
        guard
          FileManager.default.createFile(
            atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
      }
      let target = folder(of: family)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: staging, to: target)
    } catch {
      diagnostics.record(.store, .error, "theme.fontDownloadFailed")
      return .unreachable
    }
    diagnostics.record(
      .store, .info, "theme.fontDownloaded", ["files": .count(urls.count), "size": .bytes(bytes)])
    return activateKept(family) ? .available : .unreachable
  }

  /// The style sheet of a family, or `nil` when Google does not know it. Asked first with the
  /// regular, bold and italic faces; a family without all of them is asked as it is.
  private func styleSheet(of family: String) async throws -> Data? {
    let name = family.replacingOccurrences(of: " ", with: "+")
    for query in ["\(name):ital,wght@0,400;0,700;1,400;1,700", name] {
      guard let url = URL(string: "https://\(Self.cssHost)/css2?family=\(query)&display=swap")
      else { continue }
      let (data, status) = try await fetch(url)
      if status == 200 { return data }
      guard status == 400 else { throw URLError(.badServerResponse) }
    }
    return nil
  }

  /// The files a style sheet lists, on Google's own host only, each once.
  static func fileURLs(in css: String) -> [URL] {
    var urls: [URL] = []
    var rest = css[...]
    while let start = rest.range(of: "url(") {
      rest = rest[start.upperBound...]
      guard let end = rest.firstIndex(of: ")") else { break }
      let raw = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
      rest = rest[end...]
      guard let url = URL(string: raw), url.scheme == "https", url.host == fileHost,
        !urls.contains(url)
      else { continue }
      urls.append(url)
      if urls.count == maximumFiles { break }
    }
    return urls
  }

  // MARK: - Activating

  private func folder(of family: String) -> URL {
    directory.appendingPathComponent(family, isDirectory: true)
  }

  private func fontFiles(in folder: URL) -> [URL] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
      ?? []
    return files.filter {
      $0.pathExtension == "ttf"
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Activates the files kept for `family`, for this process only. Whether the family can now be
  /// drawn.
  private func activateKept(_ family: String) -> Bool {
    guard ConversationThemeFile.isFontFamily(family) else { return false }
    if registered.contains(family) { return true }
    let files = fontFiles(in: folder(of: family))
    guard !files.isEmpty else { return false }
    for file in files {
      // Already active — by another theme, or an earlier call — is not a failure.
      CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
    registered.insert(family)
    return true
  }

  static func isInstalled(_ family: String) -> Bool {
    if systemFamilies.contains(family) { return true }
    let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
    return families.contains(family)
  }

  /// Whether `data` holds at least one face CoreText can read.
  static func isFont(_ data: Data) -> Bool {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [Any]
    else { return false }
    return !descriptors.isEmpty
  }
}
