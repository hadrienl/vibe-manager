import Foundation
import Testing

@testable import VibeAgents

/// Counts the folders listed, listing them for real.
private final class Listings: @unchecked Sendable {
  private let lock = NSLock()
  private var listed: [URL] = []

  var count: Int { lock.withLock { listed.count } }

  func list(_ folder: URL) -> [URL]? {
    lock.withLock { listed.append(folder) }
    return try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  }
}

@Suite("Remembering where transcripts are (#255)")
struct TranscriptLocationCacheTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeLocations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // `/var` is a link to `/private/var`, where the listings say the files are. `realpath`, since
    // `resolvingSymlinksInPath` takes `/private` away again.
    let resolved = try #require(realpath(url.path, nil))
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  private func write(_ file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: file)
  }

  private func cache(_ root: URL, _ listings: Listings) -> TranscriptLocationCache {
    TranscriptLocationCache(
      locator: AgentTranscriptLocator(
        claudeProjects: root.appendingPathComponent("projects"),
        codexSessions: root.appendingPathComponent("sessions")),
      list: { listings.list($0) })
  }

  @Test("Claude Code: the folder named after the working directory, found without a look")
  func claudeDirect() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/-Users-me-my-app/abc.jsonl")
    try write(file)
    let listings = Listings()
    let cache = cache(root, listings)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/Users/me/my.app") == file)
    #expect(listings.count == 0)
  }

  @Test("Claude Code: found by a look through the projects once, then remembered")
  func claudeLookedForOnce() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/elsewhere/abc.jsonl")
    try write(file)
    try write(root.appendingPathComponent("projects/elsewhere/abc/subagents/agent-1.jsonl"))
    let listings = Listings()
    let cache = cache(root, listings)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/Users/me/app") == file)
    #expect(listings.count == 1)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/Users/me/app") == file)
    #expect(listings.count == 1)
    // Gone from where it was: looked for again.
    try FileManager.default.removeItem(at: file)
    let moved = root.appendingPathComponent("projects/other/abc.jsonl")
    try write(moved)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: nil) == moved)
    #expect(listings.count == 2)
  }

  @Test("Codex: the days listed are not listed again, but for the last one and those since")
  func codexDays() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
    let created = calendar.date(byAdding: .day, value: -60, to: now)!
    let first = root.appendingPathComponent("sessions/2026/08/01/rollout-1-xyz.jsonl")
    try write(first)
    let listings = Listings()
    let cache = cache(root, listings)
    #expect(cache.codexRollouts(for: "xyz", since: created, now: now) == [first])
    #expect(listings.count == 62)
    // Resumed today: a new rollout in today's folder.
    let today = root.appendingPathComponent("sessions/2026/09/30/rollout-2-xyz.jsonl")
    try write(today)
    let found = cache.codexRollouts(for: "xyz", since: created, now: now)
    #expect(Set(found) == [first, today])
    #expect(listings.count == 64)
  }

  @Test("The oldest conversations are let go of past the capacity")
  func bounded() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let listings = Listings()
    let cache = cache(root, listings)
    for index in 0...TranscriptLocationCache.capacity {
      let file = root.appendingPathComponent("projects/p/id\(index).jsonl")
      try write(file)
      _ = cache.claudeTranscript(for: "id\(index)", workingDirectory: nil)
    }
    let looks = listings.count
    // The last one is remembered, the first was let go of and is looked for again.
    _ = cache.claudeTranscript(for: "id\(TranscriptLocationCache.capacity)", workingDirectory: nil)
    #expect(listings.count == looks)
    _ = cache.claudeTranscript(for: "id0", workingDirectory: nil)
    #expect(listings.count == looks + 1)
  }

  @Test("A working directory names its Claude Code folder with dashes")
  func folderName() {
    #expect(
      TranscriptLocationCache.claudeFolderName(for: "/private/tmp/claude-501/a_b.c")
        == "-private-tmp-claude-501-a-b-c")
  }
}
