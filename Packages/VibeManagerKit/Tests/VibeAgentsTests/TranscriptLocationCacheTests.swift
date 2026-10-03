import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// Counts the folders listed, listing them for real.
private final class Listings: @unchecked Sendable {
  private let lock = NSLock()
  private var listed: [URL] = []

  var count: Int { lock.withLock { listed.count } }

  func count(of folder: URL) -> Int {
    lock.withLock { listed.filter { $0.standardizedFileURL == folder.standardizedFileURL }.count }
  }

  func list(_ folder: URL) -> [URL]? {
    lock.withLock { listed.append(folder) }
    return try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
  }
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var moment: Date
  init(_ moment: Date) { self.moment = moment }
  var now: Date { lock.withLock { moment } }
  func advance(_ seconds: TimeInterval) { lock.withLock { moment += seconds } }
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

  private func cache(
    _ root: URL, _ listings: Listings, now: @escaping @Sendable () -> Date = { Date() }
  ) -> TranscriptLocationCache {
    TranscriptLocationCache(
      locator: AgentTranscriptLocator(
        claudeProjects: root.appendingPathComponent("projects"),
        codexSessions: root.appendingPathComponent("sessions"),
        list: { listings.list($0) }),
      now: now)
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
    let cache = cache(root, listings, now: { now })
    #expect(cache.codexRollouts(for: "xyz", since: created) == [first])
    #expect(listings.count == 62)
    // Resumed today: a new rollout in today's folder.
    let today = root.appendingPathComponent("sessions/2026/09/30/rollout-2-xyz.jsonl")
    try write(today)
    let found = cache.codexRollouts(for: "xyz", since: created)
    #expect(Set(found) == [first, today])
    #expect(listings.count == 64)
  }

  @Test("Codex: a rollout deleted since it was found is not given back")
  func codexDeleted() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
    let created = calendar.date(byAdding: .day, value: -10, to: now)!
    let old = root.appendingPathComponent("sessions/2026/09/22/rollout-1-xyz.jsonl")
    try write(old)
    let cache = cache(root, Listings(), now: { now })
    #expect(cache.codexRollouts(for: "xyz", since: created) == [old])
    try FileManager.default.removeItem(at: old)
    #expect(cache.codexRollouts(for: "xyz", since: created).isEmpty)
  }

  @Test("Claude Code: a transcript not found is not looked for again at once")
  func claudeMissPaused() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
    let listings = Listings()
    let clock = Clock(Date())
    let cache = cache(root, listings, now: { clock.now })
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: nil) == nil)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: nil) == nil)
    #expect(listings.count == 1)
    // Written since, found once the pause is over.
    let file = root.appendingPathComponent("projects/p/abc.jsonl")
    try write(file)
    clock.advance(3)
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: nil) == file)
    #expect(listings.count == 2)
  }

  @Test("Claude Code: the working directory's folder is checked even during the pause")
  func directPathSkipsThePause() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
    let listings = Listings()
    let cache = cache(root, listings, now: { Date(timeIntervalSince1970: 1_000) })
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/Users/me/app") == nil)
    let file = root.appendingPathComponent("projects/-Users-me-app/abc.jsonl")
    try write(file)
    // Still within the pause: no look through the projects, but its own folder is found.
    #expect(cache.claudeTranscript(for: "abc", workingDirectory: "/Users/me/app") == file)
    #expect(listings.count == 1)
  }

  @Test("A conversation looked at again is kept: the least recently used one is let go of")
  func leastRecentlyUsed() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let listings = Listings()
    let cache = cache(root, listings)
    for index in 0...TranscriptLocationCache.capacity {
      let file = root.appendingPathComponent("projects/p/id\(index).jsonl")
      try write(file)
      _ = cache.claudeTranscript(for: "id\(index)", workingDirectory: nil)
      // The first is looked at all along: it stays.
      _ = cache.claudeTranscript(for: "id0", workingDirectory: nil)
    }
    let looks = listings.count
    _ = cache.claudeTranscript(for: "id0", workingDirectory: nil)
    #expect(listings.count == looks)
    _ = cache.claudeTranscript(for: "id1", workingDirectory: nil)
    #expect(listings.count == looks + 1)
  }

  @Test("The provider and the branch report share one memory: found once, by its folder")
  func sharedByProviderAndReader() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("projects/-Users-me-app/abc.jsonl")
    try write(file)
    let listings = Listings()
    let cache = cache(root, listings)
    let provider = ClaudeCodeAgentProvider.make(environment: [:], transcriptLocations: cache)
    let agent = SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "abc")
    let session = WorkSession(
      name: "Shared", agent: agent, repositories: [RepositoryContext(path: "/Users/me/app")])

    // The session's folder names the transcript's: no look through the projects.
    #expect(provider.conversationFiles(for: agent, in: session, hint: nil) == [file])
    let reader = AgentTranscriptReader(locations: cache)
    _ = await reader.activity(for: session)
    // Only the sub-agents' folder is listed, never the projects.
    #expect(listings.count(of: root.appendingPathComponent("projects")) == 0)
    #expect(listings.count == 1)
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
