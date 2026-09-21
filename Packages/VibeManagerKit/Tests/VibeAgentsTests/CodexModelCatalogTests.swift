import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Codex model catalog")
struct CodexModelCatalogTests {
  private func catalog(writing contents: String?) throws -> (CodexModelCatalog, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codex-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("models_cache.json")
    if let contents {
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return (CodexModelCatalog(cacheURL: url), directory)
  }

  @Test("The cache written by the CLI becomes the offered models")
  func readsCache() async throws {
    let (catalog, directory) = try catalog(
      writing: """
        {"fetched_at": "2026-09-21T19:13:50Z", "models": [
          {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "description": "…"},
          {"slug": "gpt-6-mini", "display_name": "GPT-6 Mini"}
        ]}
        """
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let models = await catalog.models()
    #expect(models.map(\.id) == ["gpt-6-astra", "gpt-6-mini"])
    #expect(models.map(\.displayName) == ["GPT-6-Astra", "GPT-6 Mini"])
    // None is the default: an empty choice means "whatever config.toml says".
    #expect(models.allSatisfy { !$0.isDefault })
  }

  @Test("A missing cache offers no model rather than a stale hard coded list")
  func missingCache() async throws {
    let (catalog, directory) = try catalog(writing: nil)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(await catalog.models().isEmpty)
  }

  @Test("A truncated cache is ignored")
  func truncatedCache() async throws {
    let (catalog, directory) = try catalog(writing: "{\"models\": [{\"slug\": \"gpt")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(await catalog.models().isEmpty)
  }

  @Test("An unexpected shape is ignored, one bad entry is skipped")
  func unexpectedShape() async throws {
    let (catalog, directory) = try catalog(
      writing: """
        {"models": ["a string", {"name": "no slug"}, {"slug": ""}, {"slug": "-dangerous"},
                    {"slug": "gpt-6-astra"}, {"slug": "gpt-6-astra"}]}
        """
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(await catalog.models().map(\.id) == ["gpt-6-astra"])
  }

  @Test("An entry without a display name falls back to its slug")
  func missingDisplayName() async throws {
    let (catalog, directory) = try catalog(writing: "{\"models\": [{\"slug\": \"gpt-6-astra\"}]}")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(await catalog.models().first?.displayName == "gpt-6-astra")
  }

  @Test("An oversized cache is refused before being read")
  func oversizedCache() async throws {
    let valid = "{\"models\": [{\"slug\": \"gpt-6-astra\"}]}"
    let (_, directory) = try catalog(writing: valid)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("models_cache.json")

    // The very same file, valid JSON, is read or refused on its size alone.
    #expect(await CodexModelCatalog(cacheURL: url).models().map(\.id) == ["gpt-6-astra"])
    let limited = CodexModelCatalog(cacheURL: url, maximumCacheByteCount: valid.utf8.count - 1)
    #expect(await limited.models().isEmpty)
  }

  @Test("A tilde prefixed CODEX_HOME is resolved like the CLI resolves it")
  func expandsTilde() {
    let environment = ["CODEX_HOME": "~/Codex", "HOME": "/Users/test"]
    #expect(CodexHome.directory(environment: environment).path == "/Users/test/Codex")
    #expect(CodexHome.sanitized(environment: environment)["CODEX_HOME"] == "/Users/test/Codex")
  }

  @Test("A CODEX_HOME this application cannot resolve is not forwarded either")
  func dropsUnresolvableCodexHome() {
    // Forwarding it would make the CLI write its sessions where discovery does not look.
    let environment = ["CODEX_HOME": "relative/codex", "HOME": "/Users/test"]
    #expect(CodexHome.sanitized(environment: environment)["CODEX_HOME"] == nil)
    #expect(CodexHome.directory(environment: environment).path == "/Users/test/.codex")
  }

  @Test("CODEX_HOME decides where the cache is read")
  func honoursCodexHome() {
    let environment = ["CODEX_HOME": "/Users/test/.config/codex", "HOME": "/Users/test"]
    #expect(
      CodexHome.modelsCacheURL(environment: environment).path
        == "/Users/test/.config/codex/models_cache.json"
    )
    #expect(
      CodexHome.sessionsDirectory(environment: ["HOME": "/Users/test"]).path
        == "/Users/test/.codex/sessions"
    )
    // A relative CODEX_HOME is meaningless for a process started elsewhere.
    #expect(
      CodexHome.directory(environment: ["CODEX_HOME": "relative", "HOME": "/Users/test"]).path
        == "/Users/test/.codex"
    )
  }
}
