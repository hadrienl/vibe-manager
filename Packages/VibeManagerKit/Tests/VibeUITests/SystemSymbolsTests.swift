import Foundation
import Testing
import VibeDomain

@testable import VibeUI

@Suite("Every SF Symbol of this Mac, for the search of the Badges settings")
struct SystemSymbolsTests {
  private func resources(_ files: [String: Any]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-symbols-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, value) in files {
      let data = try PropertyListSerialization.data(
        fromPropertyList: value, format: .binary, options: 0)
      try data.write(to: folder.appendingPathComponent(name))
    }
    return folder
  }

  @Test("A script's variants and Apple's restricted symbols are left out, in the system's order")
  func filtering() throws {
    let folder = try resources([
      "symbol_order.plist": [
        "character.book.closed", "character.book.closed.ar", "character.book.closed.hi",
        "iphone", "star", "rectangle.3d",
      ],
      "symbol_restrictions.strings": ["iphone": "May only be used to refer to Apple's iPhone."],
      "symbol_search.plist": ["star": ["favorite", "rating"]],
    ])
    defer { try? FileManager.default.removeItem(at: folder) }

    let symbols = try #require(SystemSymbols(resources: folder))

    #expect(symbols.names == ["character.book.closed", "star", "rectangle.3d"])
    #expect(symbols.keywords["star"] == ["favorite", "rating"])
  }

  @Test("Without the system's list, or with one not as expected, there is none")
  func missingOrUnexpected() throws {
    let empty = try resources([:])
    let unexpected = try resources(["symbol_order.plist": ["not": "a list"]])
    defer {
      try? FileManager.default.removeItem(at: empty)
      try? FileManager.default.removeItem(at: unexpected)
    }
    #expect(SystemSymbols(resources: empty) == nil)
    #expect(SystemSymbols(resources: unexpected) == nil)
  }

  @Test("On this Mac, the search reaches far beyond the symbols chosen, by the system's words too")
  func installed() throws {
    // CoreGlyphs is not a public interface: where it cannot be read, the search keeps its own list.
    guard let symbols = SystemSymbols.installed else { return }
    #expect(symbols.names.count > SymbolCatalog.names.count)
    #expect(symbols.names.contains("wrench.and.screwdriver"))
    #expect(!symbols.names.contains { $0.hasSuffix(".ar") })
    let found = SymbolCatalog.search("date", excluding: .default)
    #expect(found.contains { $0.contains("calendar") })
  }
}
