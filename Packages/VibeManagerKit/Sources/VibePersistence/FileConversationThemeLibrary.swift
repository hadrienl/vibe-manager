import Foundation
import VibeApplication

/// The personal themes of the conversation view (#118), one file each in `Themes/`, beside the
/// session store:
///
/// ```
/// Themes/          0700
///   <uuid>.json    0600, the file of the theme `personal-<uuid>`
/// ```
///
/// No index and no lock: a file per theme written in one rename is all there is to keep, and two
/// instances cannot write the same identifier. The order is the order the files were made in.
/// A file that cannot be read — or whose colours cannot be — is left out, left where it is, and
/// said: the user decides.
public struct FileConversationThemeLibrary: ConversationThemeLibrary {
  static let fileExtension = "json"
  static let stagingPrefix = ".staging-"

  private let directory: URL
  private let diagnostics: Diagnostics
  /// The built-in themes' names as the user reads them: a personal theme takes none.
  private let localizedBuiltInNames: [String]
  /// The families fetched from Google Fonts: activated when the library is read, and carried by
  /// an export.
  private let fonts: GoogleThemeFonts?
  /// The pictures behind the themes: found when a theme is read, and carried by an export.
  private let images: (any ThemeImageStoring)?

  public init(
    directory: URL, diagnostics: Diagnostics = .disabled, localizedBuiltInNames: [String] = [],
    fonts: GoogleThemeFonts? = nil, images: (any ThemeImageStoring)? = nil
  ) {
    self.directory = directory
    self.diagnostics = diagnostics
    self.localizedBuiltInNames = localizedBuiltInNames
    self.fonts = fonts
    self.images = images
  }

  public func load() async -> ThemeLibraryContents {
    await fonts?.activateAll()
    return read(recording: true)
  }

  public func save(_ theme: ConversationTheme, name: String) async throws -> ConversationTheme {
    let others = read(recording: false).themes.filter { $0.id != theme.id }.compactMap(
      \.personalName)
    let unique = ConversationThemeLibraryRules.uniqueName(
      name, among: others + ConversationThemeLibraryRules.builtInNames + localizedBuiltInNames)
    let kept = ConversationThemeLibraryRules.kept(theme, name: unique)
    let fileManager = FileManager.default
    let staging = directory.appendingPathComponent(
      Self.stagingPrefix + UUID().uuidString, isDirectory: false)
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard
        fileManager.createFile(
          atPath: staging.path, contents: ConversationThemeFile.encode(kept),
          attributes: [.posixPermissions: 0o600])
      else { throw ThemeLibraryError.couldNotWrite }
      // One rename: the file is either the old one or the new one, never half of either.
      guard rename(staging.path, file(of: kept.id).path) == 0 else {
        throw ThemeLibraryError.couldNotWrite
      }
    } catch {
      try? fileManager.removeItem(at: staging)
      diagnostics.record(.store, .error, "theme.saveFailed")
      throw ThemeLibraryError.couldNotWrite
    }
    diagnostics.record(.store, .info, "theme.saved")
    return kept
  }

  public func remove(_ id: String) async throws {
    let url = file(of: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ThemeLibraryError.notFound
    }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      diagnostics.record(.store, .error, "theme.removeFailed")
      throw ThemeLibraryError.couldNotRemove
    }
    diagnostics.record(.store, .info, "theme.removed")
  }

  public func archive(_ id: String, preview: Data?) async throws -> Data {
    guard let data = contents(of: file(of: id)) else { throw ThemeLibraryError.notFound }
    var files = [DiagnosticFile(name: "theme.json", contents: data)]
    if let preview { files.append(DiagnosticFile(name: "preview.png", contents: preview)) }
    let theme = try? ConversationThemeFile.decode(data, id: id)
    if let name = theme?.backdrop.image, let url = images?.location(of: name),
      let picture = try? Data(contentsOf: url)
    {
      files.append(DiagnosticFile(name: "backdrop.jpg", contents: picture))
    }
    // The families fetched for it: whoever imports the theme has them without Google.
    if let fonts, let theme {
      for family in Set([theme.fonts.message, theme.fonts.code].compactMap { $0 }).sorted() {
        for file in await fonts.files(of: family) {
          guard let contents = try? Data(contentsOf: file) else { continue }
          files.append(
            DiagnosticFile(name: "fonts/\(family)/\(file.lastPathComponent)", contents: contents))
        }
      }
    }
    return ZipArchiveWriter.archive(files)
  }

  public func location(ofFile fileName: String) -> URL? {
    directory.appendingPathComponent(fileName, isDirectory: false)
  }

  /// The file of the theme `id`: its identifier without the prefix every personal one has.
  func file(of id: String) -> URL {
    let stem =
      id.hasPrefix(ConversationTheme.personalPrefix)
      ? String(id.dropFirst(ConversationTheme.personalPrefix.count)) : id
    // An identifier comes from a file name of this folder, or from a UUID: never a path.
    let safe = stem.replacingOccurrences(of: "/", with: "_")
    return directory.appendingPathComponent("\(safe).\(Self.fileExtension)", isDirectory: false)
  }

  private func read(recording: Bool) -> ThemeLibraryContents {
    let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return ThemeLibraryContents(themes: [], problems: []) }
    var themes: [ConversationTheme] = []
    var problems: [ThemeLoadProblem] = []
    var files: [(url: URL, created: Date)] = []
    for url in urls where url.pathExtension == Self.fileExtension {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      // A link, or a folder, is never followed: said like a file that is not a theme.
      guard values.isRegularFile == true else {
        problems.append(ThemeLoadProblem(fileName: url.lastPathComponent, problem: .notJSON))
        if recording {
          diagnostics.record(
            .store, .notice, "theme.unreadable",
            ["problem": .token(ThemeFileProblem.Code.notJSON.diagnosticToken)])
        }
        continue
      }
      files.append((url, values.creationDate ?? .distantPast))
    }
    files.sort { first, second in
      first.created == second.created
        ? first.url.lastPathComponent < second.url.lastPathComponent
        : first.created < second.created
    }
    for (url, _) in files {
      let id = ConversationTheme.personalPrefix + url.deletingPathExtension().lastPathComponent
      do throws(ThemeFileProblem) {
        guard let data = contents(of: url) else { throw .tooLarge }
        var theme = try ConversationThemeFile.theme(from: data, id: id)
        // A picture gone is not a reason to lose the theme: it is drawn without it.
        theme.backdrop.localImage = theme.backdrop.image.flatMap { images?.location(of: $0) }
        themes.append(theme)
      } catch {
        problems.append(ThemeLoadProblem(fileName: url.lastPathComponent, problem: error))
        if recording {
          diagnostics.record(
            .store, .notice, "theme.unreadable", ["problem": .token(error.code.diagnosticToken)])
        }
      }
    }
    return ThemeLibraryContents(themes: themes, problems: problems)
  }

  /// A file of the folder, read only when it is small enough to be a theme.
  private func contents(of url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let limit = ConversationThemeFile.maximumSize
    let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
    return data.count <= limit ? data : nil
  }
}
