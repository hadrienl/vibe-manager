import Foundation
import Testing

/// Every French string of every catalog — the package's modules and the application's — with
/// French typography (docs/localization.md): a no-break space, never a breakable one, before
/// `:` `;` `?` `!` and inside « ». A line never starts with the colon of the line above.
@Suite("French typography in every catalog")
struct FrenchTypographyTests {
  /// The repository, from this file: `Packages/VibeManagerKit/Tests/VibeUITests/`.
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// The catalogs: `Sources/*/Localizable.xcstrings` in the package, every `.xcstrings` of `App`.
  static func catalogs() -> [URL] {
    let fileManager = FileManager.default
    var found: [URL] = []
    for folder in ["Packages/VibeManagerKit/Sources", "App"] {
      let root = repository.appendingPathComponent(folder)
      guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let url as URL in walker where url.pathExtension == "xcstrings" {
        found.append(url)
      }
    }
    return found.sorted { $0.path < $1.path }
  }

  /// Every French value of a catalog, plural and device variants included, with its key.
  static func frenchValues(of catalog: URL) throws -> [(key: String, value: String)] {
    let data = try Data(contentsOf: catalog)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let strings = object?["strings"] as? [String: Any] ?? [:]
    var values: [(String, String)] = []
    func walk(_ node: Any, key: String) {
      if let dictionary = node as? [String: Any] {
        if let unit = dictionary["stringUnit"] as? [String: Any],
          let value = unit["value"] as? String
        {
          values.append((key, value))
        }
        for child in dictionary.values { walk(child, key: key) }
      } else if let array = node as? [Any] {
        for child in array { walk(child, key: key) }
      }
    }
    for (key, entry) in strings {
      let french = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["fr"]
      if let french { walk(french, key: key) }
    }
    return values
  }

  /// A breakable space where French wants a no-break one.
  static func breakableSpace(in text: String) -> Bool {
    text.range(of: #" [:;?!»]|« "#, options: .regularExpression) != nil
  }

  @Test("The rule tells a breakable space from a no-break one")
  func rule() {
    #expect(Self.breakableSpace(in: "Supprimer « %@ » ?"))
    #expect(Self.breakableSpace(in: "Échec : %@"))
    #expect(!Self.breakableSpace(in: "Supprimer «\u{00A0}%@\u{00A0}»\u{00A0}?"))
    #expect(!Self.breakableSpace(in: "Échec\u{202F}: %@, http://exemple.fr"))
  }

  @Test("Every catalog is found, the application's included")
  func catalogsFound() {
    let names = Self.catalogs().map { $0.deletingLastPathComponent().lastPathComponent }
    #expect(names.contains("VibeUI"))
    #expect(names.contains("VibeApplication"))
    #expect(names.contains("VibeConversationUI"))
    #expect(names.contains("VibeManagerApp"))
  }

  @Test("No French string has a breakable space before : ; ? ! or inside « »")
  func noBreakableSpace() throws {
    for catalog in Self.catalogs() {
      let name = catalog.path.replacingOccurrences(of: Self.repository.path + "/", with: "")
      for (key, value) in try Self.frenchValues(of: catalog) where Self.breakableSpace(in: value) {
        Issue.record("\(name): “\(key)” → “\(value)”")
      }
    }
  }
}
