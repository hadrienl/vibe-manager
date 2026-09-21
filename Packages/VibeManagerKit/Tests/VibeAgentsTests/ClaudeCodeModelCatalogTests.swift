import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Claude Code model catalog")
struct ClaudeCodeModelCatalogTests {
  private func directory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("claude-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(
    _ contents: String,
    named name: String,
    in directory: URL,
    modifiedAt: Date = Date()
  ) throws {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
  }

  private func cache(
    surface: String,
    fetchedAt: Double,
    models: String
  ) -> String {
    """
    {"version":2,"fetchedAt":\(fetchedAt),"staleAt":0,
     "catalog":{"surface":"\(surface)","config":{"id":"\(surface)","models":[\(models)]}}}
    """
  }

  private static let models = """
    {"id":"claude-opus-5","name":"Opus 5","section":"main"},
    {"id":"claude-sonnet-5","name":"Sonnet 5","section":"main"},
    {"id":"claude-opus-4-8","name":"Opus 4.8","section":"overflow"}
    """

  @Test("Main models come first, then the overflow ones, in declared order")
  func ordersSections() async throws {
    let directory = try directory()
    try write(
      cache(surface: "cc", fetchedAt: 10, models: Self.models), named: "org-cc.json", in: directory)

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.map(\.id) == ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-8"])
    #expect(models.map(\.displayName) == ["Opus 5", "Sonnet 5", "Opus 4.8"])
    // Passing no model at all is what leaves the user's own setting in charge.
    #expect(models.allSatisfy { !$0.isDefault })
  }

  @Test("The CLI's own surface wins over the desktop one, however fresh the desktop one is")
  func prefersCommandLineSurface() async throws {
    let directory = try directory()
    // Real names are random hashes, and the desktop caches are written far more often.
    for index in 0..<12 {
      try write(
        cache(surface: "ccd", fetchedAt: 99, models: #"{"id":"desktop-only","section":"main"}"#),
        named: "tok-\(index)-ccd.json",
        in: directory,
        modifiedAt: Date()
      )
    }
    try write(
      cache(surface: "cc", fetchedAt: 1, models: Self.models),
      named: "7c7-abc-cc.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 1)
    )

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.first?.id == "claude-opus-5")
    #expect(!models.contains { $0.id == "desktop-only" })
  }

  @Test("A file whose name lies about its surface is judged on its contents")
  func trustsContentsOverNames() async throws {
    let directory = try directory()
    try write(
      cache(surface: "ccd", fetchedAt: 1, models: #"{"id":"desktop-only","section":"main"}"#),
      named: "liar-cc.json",
      in: directory
    )
    try write(
      cache(surface: "cc", fetchedAt: 1, models: Self.models),
      named: "honest.json",
      in: directory
    )

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.first?.id == "claude-opus-5")
  }

  @Test("Without the CLI surface the freshest catalog is used rather than none")
  func fallsBackToOtherSurfaces() async throws {
    let directory = try directory()
    try write(
      cache(surface: "ccd", fetchedAt: 1, models: #"{"id":"old-model","section":"main"}"#),
      named: "a.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 1_000)
    )
    try write(
      cache(surface: "ccd", fetchedAt: 2, models: #"{"id":"new-model","section":"main"}"#),
      named: "b.json",
      in: directory,
      modifiedAt: Date(timeIntervalSince1970: 2_000)
    )

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.map(\.id) == ["new-model"])
  }

  @Test("A missing, empty, truncated or oversized cache offers no model instead of failing")
  func toleratesUnusableCaches() async throws {
    let missing = await ClaudeCodeModelCatalog(
      directory: URL(fileURLWithPath: "/nonexistent/model-catalog")
    ).models()
    #expect(missing.isEmpty)

    let directory = try directory()
    try write("", named: "empty.json", in: directory)
    try write("{\"catalog\":{\"config\":{\"models\":[", named: "truncated.json", in: directory)
    try write("{\"catalog\":{\"config\":{}}}", named: "no-models.json", in: directory)
    try write("not json at all", named: "garbage.json", in: directory)
    #expect(await ClaudeCodeModelCatalog(directory: directory).models().isEmpty)

    try write(
      cache(surface: "cc", fetchedAt: 1, models: Self.models), named: "cc.json", in: directory)
    let bounded = await ClaudeCodeModelCatalog(directory: directory, maximumCacheByteCount: 8)
      .models()
    #expect(bounded.isEmpty)
  }

  @Test("A malformed entry is dropped without discarding the catalog")
  func dropsMalformedEntries() async throws {
    let directory = try directory()
    try write(
      cache(
        surface: "cc",
        fetchedAt: 1,
        models: """
          {"name":"No identifier","section":"main"},
          {"id":"-dash","section":"main"},
          {"id":"vendor/model","section":"main"},
          {"id":"claude-opus-5","name":"Opus 5","section":"main"},
          {"id":"claude-opus-5","name":"Duplicate","section":"overflow"}
          """
      ),
      named: "cc.json",
      in: directory
    )

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.map(\.id) == ["claude-opus-5"])
    #expect(models.first?.displayName == "Opus 5")
  }

  @Test("A model without a display name falls back to its identifier")
  func usesIdentifierAsFallbackName() async throws {
    let directory = try directory()
    try write(
      cache(surface: "cc", fetchedAt: 1, models: #"{"id":"claude-haiku-4-5","section":"main"}"#),
      named: "cc.json",
      in: directory
    )

    let models = await ClaudeCodeModelCatalog(directory: directory).models()

    #expect(models.map(\.displayName) == ["claude-haiku-4-5"])
  }
}
