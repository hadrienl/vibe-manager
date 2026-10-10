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
  /// The families the faces of a file belong to. CoreText in the application.
  public typealias FaceFamilies = @Sendable (Data) -> Set<String>

  /// Families every Mac has under a name CoreText does not list as such.
  static let systemFamilies: Set<String> = ["SF Pro", "SF Mono", "New York"]
  /// No face of a family weighs more; a whole family is a few of them.
  static let maximumFileSize = 8 * 1024 * 1024
  static let maximumFiles = 8
  static let cssHost = "fonts.googleapis.com"
  static let fileHost = "fonts.gstatic.com"

  private let directory: URL
  private let fetch: Fetch
  private let faceFamilies: FaceFamilies
  private let diagnostics: Diagnostics
  private var registered: Set<String> = []
  /// What Google gave an export for a family installed here, empty when nothing: asked once a
  /// launch, kept in memory only.
  private var exported: [String: [Data]] = [:]

  public init(
    directory: URL, diagnostics: Diagnostics = .disabled,
    fetch: @escaping Fetch = GoogleThemeFonts.urlSession,
    faceFamilies: @escaping FaceFamilies = GoogleThemeFonts.families(in:)
  ) {
    self.directory = directory
    self.diagnostics = diagnostics
    self.fetch = fetch
    self.faceFamilies = faceFamilies
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

  /// The faces an export carries for `family` (#361), named as in the archive: the files kept,
  /// or — for a family installed on this Mac, never fetched — Google's, fetched now, so that the
  /// Mac that imports the theme has it too. Those are held in memory, never kept: kept, they would
  /// be activated over the family installed. None for a family Google does not serve — a font
  /// bought or made for a company is the user's to give, not the application's — nor for one that
  /// comes with macOS, which Google is not even asked about.
  public func exportedFaces(of family: String) async -> [(name: String, contents: Data)] {
    let kept = files(of: family).compactMap { file in
      (try? Data(contentsOf: file)).map { (file.lastPathComponent, $0) }
    }
    guard kept.isEmpty, ConversationThemeFile.isFontFamily(family),
      !Self.comesWithMacOS(family)
    else { return kept }
    if exported[family] == nil {
      exported[family] = await downloadFaces(of: family).faces
    }
    return (exported[family] ?? []).enumerated().map { ("\($0.offset).ttf", $0.element) }
  }

  /// Keeps and activates the faces of `family` an imported archive carried (#361), unless the
  /// family is installed or kept already. Only faces of that very family are kept — anything else
  /// would be activated for nothing, or over another family —, within the bounds of a family
  /// fetched from Google. Whether the family can now be drawn.
  public func install(_ family: String, faces: [Data]) -> Bool {
    guard ConversationThemeFile.isFontFamily(family) else { return false }
    if Self.isInstalled(family) || activateKept(family) { return true }
    let fonts = faces.filter {
      $0.count <= Self.maximumFileSize && faceFamilies($0).contains(family)
    }
    .prefix(Self.maximumFiles)
    guard !fonts.isEmpty else { return false }
    do {
      try keep(Array(fonts), as: family)
    } catch {
      diagnostics.record(.store, .error, "theme.fontInstallFailed")
      return false
    }
    diagnostics.record(.store, .info, "theme.fontInstalled", ["files": .count(fonts.count)])
    return activateKept(family)
  }

  /// Writes `faces` as the files of `family`, whole or not at all: into a folder of their own,
  /// renamed into place once every file is written.
  private func keep(_ faces: [Data], as family: String) throws {
    let staging = directory.appendingPathComponent(
      ".staging-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for (index, data) in faces.enumerated() {
      let file = staging.appendingPathComponent("\(index).ttf")
      guard
        FileManager.default.createFile(
          atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
    }
    let target = folder(of: family)
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: staging, to: target)
  }

  // MARK: - Fetching

  /// Fetches the faces of `family`, keeps them and activates them.
  private func download(_ family: String) async -> FontAvailability {
    let (faces, availability) = await downloadFaces(of: family)
    guard availability == .available else { return availability }
    do {
      try keep(faces, as: family)
    } catch {
      diagnostics.record(.store, .error, "theme.fontDownloadFailed")
      return .unreachable
    }
    return activateKept(family) ? .available : .unreachable
  }

  /// The faces Google serves for `family`, none when it cannot give them all.
  private func downloadFaces(of family: String) async -> (
    faces: [Data], availability: FontAvailability
  ) {
    let css: Data
    do {
      guard let found = try await styleSheet(of: family) else {
        diagnostics.record(.store, .notice, "theme.fontUnknown")
        return ([], .unknown)
      }
      css = found
    } catch {
      diagnostics.record(.store, .notice, "theme.fontUnreachable")
      return ([], .unreachable)
    }
    let urls = Self.fileURLs(in: String(decoding: css, as: UTF8.self))
    guard !urls.isEmpty else { return ([], .unknown) }
    var faces: [Data] = []
    do {
      for url in urls {
        let (data, status) = try await fetch(url)
        guard status == 200, data.count <= Self.maximumFileSize, Self.isFont(data) else {
          throw CocoaError(.fileReadCorruptFile)
        }
        faces.append(data)
      }
    } catch {
      diagnostics.record(.store, .error, "theme.fontDownloadFailed")
      return ([], .unreachable)
    }
    diagnostics.record(
      .store, .info, "theme.fontDownloaded",
      ["files": .count(urls.count), "size": .bytes(faces.reduce(0) { $0 + $1.count })])
    return (faces, .available)
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
    // The folder of this very name: the file system ignores case, CoreText does not — "roboto"
    // is not drawn by the faces of "Roboto".
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    guard names.contains(family) else { return false }
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

  /// Whether every face of `family` on this Mac comes with macOS: Menlo, Avenir, Helvetica Neue…
  /// Google serves none of them.
  static func comesWithMacOS(_ family: String) -> Bool {
    if systemFamilies.contains(family) { return true }
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontFamilyNameAttribute: family] as CFDictionary)
    let faces =
      CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
    let files = faces.compactMap {
      CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL
    }
    return !files.isEmpty && files.allSatisfy { $0.path.hasPrefix("/System/") }
  }

  /// The families of the faces in `data`, as CoreText draws them; none for what is not a font.
  public static func families(in data: Data) -> Set<String> {
    let faces = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
    return Set(
      (faces ?? []).compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
  }

  /// Whether `data` holds at least one face CoreText can read.
  static func isFont(_ data: Data) -> Bool {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [Any]
    else { return false }
    return !descriptors.isEmpty
  }
}
