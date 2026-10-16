import Foundation

/// A file of the library that could not be read. It stays where it is: the user decides.
public struct ThemeLoadProblem: Hashable, Sendable {
  /// The file's name, without its folder.
  public let fileName: String
  public let problem: ThemeFileProblem

  public init(fileName: String, problem: ThemeFileProblem) {
    self.fileName = fileName
    self.problem = problem
  }
}

/// What reading the library gives: the themes, oldest first, and the files left out.
public struct ThemeLibraryContents: Hashable, Sendable {
  public let themes: [ConversationTheme]
  public let problems: [ThemeLoadProblem]

  public init(themes: [ConversationTheme], problems: [ThemeLoadProblem]) {
    self.themes = themes
    self.problems = problems
  }
}

public enum ThemeLibraryError: Error, Hashable, Sendable {
  case couldNotWrite
  case couldNotRemove
  case notFound
}

/// Why an archive could not be imported (#361). Nothing was written.
public enum ThemeImportError: Error, Hashable, Sendable {
  /// Not a zip archive, or one without a theme file.
  case notATheme
  case tooLarge
  /// Its theme file was refused, and why.
  case file(ThemeFileProblem)
  case couldNotWrite
}

/// A theme imported (#361), and the families it asks for that could be found neither in its
/// archive, nor on this Mac, nor on Google Fonts: the default font draws in their place.
public struct ThemeImport: Hashable, Sendable {
  public let theme: ConversationTheme
  public let missingFonts: [String]

  public init(theme: ConversationTheme, missingFonts: [String] = []) {
    self.theme = theme
    self.missingFonts = missingFonts
  }
}

/// The user's own themes (#118): one file each, named by the theme's identifier.
public protocol ConversationThemeLibrary: Sendable {
  func load() async -> ThemeLibraryContents
  /// Writes `theme` under `name`, made unique among the library's and the built-in ones. The theme
  /// as it was kept.
  func save(_ theme: ConversationTheme, name: String) async throws -> ConversationTheme
  func remove(_ id: String) async throws
  /// A `.zip` of the theme's file, `theme.json`, and of `preview`, when given, as `preview.png`.
  func archive(_ id: String, preview: Data?) async throws -> Data
  /// Keeps the theme of an archive `archive` made, wherever it was made (#361): a new theme of
  /// the user's, named as in the archive, made unique. Throws `ThemeImportError`.
  func importArchive(_ data: Data) async throws -> ThemeImport
  /// Where the file of a theme, or of a problem, is: shown in the Finder. `nil` when there is no
  /// folder.
  func location(ofFile fileName: String) -> URL?
}

/// The rules every library follows, apart from where it keeps its themes.
public enum ConversationThemeLibraryRules {
  /// `name`, or `name 2`, `name 3`… — the first that no theme has, whatever the case and the
  /// accents. `reserved` are the names already taken.
  public static func uniqueName(_ name: String, among reserved: [String]) -> String {
    // A name too long is cut rather than lost.
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base =
      ConversationThemeFile.sanitizedName(
        String(trimmed.prefix(ConversationThemeFile.maximumNameLength))) ?? fallbackName
    let taken = Set(reserved.map(folded))
    guard taken.contains(folded(base)) else { return base }
    var index = 2
    while true {
      let suffix = " \(index)"
      let stem = String(base.prefix(ConversationThemeFile.maximumNameLength - suffix.count))
      let candidate = stem.trimmingCharacters(in: .whitespaces) + suffix
      if !taken.contains(folded(candidate)) { return candidate }
      index += 1
    }
  }

  /// The names of the built-in themes, in English and as the user reads them: a personal theme
  /// takes neither.
  public static let builtInNames = [
    "System Light", "System Dark", "Paper", "Night", "Terminal", "High Contrast",
  ]

  static let fallbackName = "Theme"

  /// The identifier a theme read from an archive has until it is kept: not a personal one, so
  /// that keeping it gives it its own.
  public static let importedID = "imported"

  static func folded(_ name: String) -> String {
    name.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  /// The theme as the library keeps it: named, and a personal theme whatever it was generated as.
  public static func kept(_ theme: ConversationTheme, name: String) -> ConversationTheme {
    var kept = theme
    if !theme.isPersonal {
      var colors = theme.colors
      colors[.bubbleBorder] = theme.bubbleBorder
      kept =
        ConversationTheme(
          id: ConversationTheme.personalPrefix + UUID().uuidString.lowercased(),
          isDark: theme.isDark, fontStyle: theme.fontStyle, colors: colors) ?? theme
      kept.fonts = theme.fonts
      kept.layout = theme.layout
      kept.backdrop = theme.backdrop
    }
    kept.personalName = name
    // What the user chose apart from the theme is not the theme's.
    kept.messageFontFamily = nil
    kept.codeFontFamily = nil
    return kept
  }

}

/// Kept for this run only: a workspace assembled without the system around it, and the tests.
public actor InMemoryConversationThemeLibrary: ConversationThemeLibrary {
  private var themes: [ConversationTheme]
  private let problems: [ThemeLoadProblem]
  private let localizedBuiltInNames: [String]

  public init(
    themes: [ConversationTheme] = [], problems: [ThemeLoadProblem] = [],
    localizedBuiltInNames: [String] = []
  ) {
    self.themes = themes
    self.problems = problems
    self.localizedBuiltInNames = localizedBuiltInNames
  }

  public func load() -> ThemeLibraryContents {
    ThemeLibraryContents(themes: themes, problems: problems)
  }

  public func save(_ theme: ConversationTheme, name: String) -> ConversationTheme {
    let others = themes.filter { $0.id != theme.id }.compactMap(\.personalName)
    let unique = ConversationThemeLibraryRules.uniqueName(
      name,
      among: others + ConversationThemeLibraryRules.builtInNames + localizedBuiltInNames)
    let kept = ConversationThemeLibraryRules.kept(theme, name: unique)
    themes.removeAll { $0.id == kept.id }
    themes.append(kept)
    return kept
  }

  public func remove(_ id: String) throws {
    guard themes.contains(where: { $0.id == id }) else { throw ThemeLibraryError.notFound }
    themes.removeAll { $0.id == id }
  }

  /// The theme's file alone: a library in memory keeps no picture.
  public func archive(_ id: String, preview _: Data?) throws -> Data {
    guard let theme = themes.first(where: { $0.id == id }) else {
      throw ThemeLibraryError.notFound
    }
    return ConversationThemeFile.encode(theme)
  }

  /// The theme's file alone, as `archive` gives it.
  public func importArchive(_ data: Data) throws -> ThemeImport {
    let theme: ConversationTheme
    do {
      theme = try ConversationThemeFile.theme(
        from: data, id: ConversationThemeLibraryRules.importedID)
    } catch {
      throw ThemeImportError.file(error)
    }
    return ThemeImport(theme: save(theme, name: theme.personalName ?? ""))
  }

  public nonisolated func location(ofFile _: String) -> URL? { nil }
}
