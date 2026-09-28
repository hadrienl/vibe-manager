import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Codex resume identifier extraction")
struct CodexResumeIdentifierExtractorTests {
  private let extractor = CodexResumeIdentifierExtractor()
  private let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"

  @Test("A session line yields its identifier")
  func plainLine() {
    #expect(extractor.resumeIdentifier(in: "session id: \(identifier)") == identifier)
  }

  @Test("Colour sequences do not hide the identifier")
  func colouredLine() {
    let chunk = "\u{1B}[1;32m  Session ID\u{1B}[0m: \u{1B}[2m\(identifier)\u{1B}[0m\r\n"
    #expect(extractor.resumeIdentifier(in: chunk) == identifier)
  }

  @Test("An operating system command sequence is skipped")
  func osc() {
    let chunk = "\u{1B}]0;codex\u{07}session \(identifier)\n"
    #expect(extractor.resumeIdentifier(in: chunk) == identifier)
  }

  @Test("An identifier without a session label is ignored")
  func requiresContext() {
    // The terminal echoes the prompt, which may very well contain a UUID of its own.
    #expect(extractor.resumeIdentifier(in: "Please migrate the row \(identifier)") == nil)
  }

  @Test(
    "A malformed identifier is ignored",
    arguments: [
      "session id: 019ee0a1-06d9-7e52-957b",
      "session id: 019ee0a106d97e52957bd61a982d6b43",
      "session id: zzzzzzzz-06d9-7e52-957b-d61a982d6b43",
      "session id:",
    ]
  )
  func malformed(chunk: String) {
    #expect(extractor.resumeIdentifier(in: chunk) == nil)
  }

  @Test("An identifier split across two chunks is not half read")
  func splitChunk() {
    #expect(extractor.resumeIdentifier(in: "session id: 019ee0a1-06d9-7e52") == nil)
  }
}

@Suite("Codex rollout discovery")
struct CodexRolloutSessionDiscoveryTests {
  private static let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"

  /// - Returns: the dated folder rollouts are written into, and the root to delete.
  ///
  /// The folder carries today's date, the way Codex files its own sessions, because
  /// discovery prunes dated folders older than the launch.
  private func makeSessionsDirectory(on date: Date = Date()) throws -> (day: URL, root: URL) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codex-sessions-\(UUID().uuidString)", isDirectory: true)
    let day =
      root
      .appendingPathComponent(String(format: "%04d", components.year ?? 2026), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.month ?? 1), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", components.day ?? 1), isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    return (day, root)
  }

  @discardableResult
  private func writeRollout(
    in directory: URL,
    identifier: String = CodexRolloutSessionDiscoveryTests.identifier,
    cwd: String,
    createdAt: Date,
    terminated: Bool = true,
    name: String? = nil,
    startedAt: Date? = nil
  ) throws -> URL {
    let url = directory.appendingPathComponent(
      name ?? "rollout-2026-09-21T17-19-47-\(identifier).jsonl")
    // Codex dates the session when its process starts, and writes the file with the first message.
    let started = startedAt.map { #","timestamp":"\#(Self.iso8601($0))""# } ?? ""
    var line = """
      {"timestamp":"2026-09-21T17:19:47.000Z","type":"session_meta","payload":\
      {"session_id":"\(identifier)","cwd":"\(cwd)","originator":"codex-tui"\(started)}}
      """
    if terminated { line += "\n" }
    try line.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
    return url
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func discovery(
    _ root: URL,
    claims: CodexSessionClaims = CodexSessionClaims()
  ) -> CodexRolloutSessionDiscovery {
    CodexRolloutSessionDiscovery(
      sessionsDirectory: root,
      pollInterval: .milliseconds(10),
      claims: claims
    )
  }

  @Test("The rollout of the session just started is found")
  func findsRollout() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    try writeRollout(in: day, cwd: "/Users/test/app", createdAt: launchedAt)

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: launchedAt,
      timeout: .seconds(1)
    )
    #expect(found == Self.identifier)
  }

  @Test("A rollout from another working directory is not attributed to this pane")
  func ignoresOtherDirectory() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    try writeRollout(in: day, cwd: "/Users/test/other", createdAt: launchedAt)

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: launchedAt,
      timeout: .milliseconds(100)
    )
    #expect(found == nil)
  }

  @Test("A rollout older than the launch belongs to a previous session")
  func ignoresOlderRollout() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    try writeRollout(
      in: day,
      cwd: "/Users/test/app",
      createdAt: launchedAt.addingTimeInterval(-3600)
    )

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: launchedAt,
      timeout: .milliseconds(100)
    )
    #expect(found == nil)
  }

  @Test("The session started for this pane wins over one started right after it")
  func prefersOldestAfterLaunch() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    // Another pane, same repository, a second later: the newest rollout is not ours.
    let laterPane = "019ee0a1-9999-7e52-957b-d61a982d6b43"
    try writeRollout(
      in: day,
      cwd: "/Users/test/app",
      createdAt: launchedAt.addingTimeInterval(1)
    )
    try writeRollout(
      in: day,
      identifier: laterPane,
      cwd: "/Users/test/app",
      createdAt: launchedAt.addingTimeInterval(2),
      name: "rollout-later-\(laterPane).jsonl"
    )

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: launchedAt,
      timeout: .seconds(1)
    )
    #expect(found == Self.identifier)
  }

  @Test("A rollout from a folder dated before the launch is pruned, not walked")
  func prunesOlderDatedFolders() async throws {
    let (_, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lastYear = root.appendingPathComponent("2020/01/02", isDirectory: true)
    try FileManager.default.createDirectory(at: lastYear, withIntermediateDirectories: true)

    #expect(
      discovery(root).isEntirelyBefore(directory: lastYear, floor: Date())
    )
    #expect(
      !discovery(root).isEntirelyBefore(
        directory: root.appendingPathComponent("2999", isDirectory: true), floor: Date())
    )
    // An unexpected layout is walked rather than skipped.
    #expect(
      !discovery(root).isEntirelyBefore(
        directory: root.appendingPathComponent("archive", isDirectory: true), floor: Date())
    )
  }

  @Test("A rollout whose first line is not written yet is skipped, then read")
  func waitsForCompleteFirstLine() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    let url = try writeRollout(
      in: day,
      cwd: "/Users/test/app",
      createdAt: launchedAt,
      terminated: false
    )

    #expect(
      await discovery(root).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: launchedAt,
        timeout: .milliseconds(100)
      ) == nil
    )

    // The same file, once the CLI finished writing its first line.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()

    #expect(
      await discovery(root).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: launchedAt,
        timeout: .seconds(1)
      ) == Self.identifier
    )
  }

  @Test("A symlinked working directory still matches")
  func matchesThroughSymlink() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launchedAt = Date()
    // `/tmp` is a symlink to `/private/tmp`: the same directory under two names.
    try writeRollout(in: day, cwd: "/private/tmp", createdAt: launchedAt)

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/tmp",
      since: launchedAt,
      timeout: .seconds(1)
    )
    #expect(found == Self.identifier)
  }

  @Test("A pane started second does not adopt the session of the pane started first")
  func doesNotAdoptEarlierPane() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let claims = CodexSessionClaims()

    // The first pane launches and its rollout appears half a second later.
    let firstLaunch = Date()
    try writeRollout(
      in: day,
      cwd: "/Users/test/app",
      createdAt: firstLaunch.addingTimeInterval(0.5)
    )
    #expect(
      await discovery(root, claims: claims).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: firstLaunch,
        timeout: .seconds(1)
      ) == Self.identifier)

    // A second pane, same repository, a second later: that rollout is not its own.
    let secondPane = "019ee0a1-9999-7e52-957b-d61a982d6b43"
    let secondLaunch = firstLaunch.addingTimeInterval(1)
    #expect(
      await discovery(root, claims: claims).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: secondLaunch,
        timeout: .milliseconds(100)
      ) == nil)

    // It waits for the rollout it did create.
    try writeRollout(
      in: day,
      identifier: secondPane,
      cwd: "/Users/test/app",
      createdAt: secondLaunch.addingTimeInterval(0.5),
      name: "rollout-second-\(secondPane).jsonl"
    )
    #expect(
      await discovery(root, claims: claims).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: secondLaunch,
        timeout: .seconds(1)
      ) == secondPane)
  }

  @Test("A session already claimed by another pane is never handed out twice")
  func claimsAreExclusive() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let claims = CodexSessionClaims()
    let launchedAt = Date()
    try writeRollout(in: day, cwd: "/Users/test/app", createdAt: launchedAt)

    #expect(await claims.claim(Self.identifier))
    #expect(
      await discovery(root, claims: claims).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: launchedAt,
        timeout: .milliseconds(100)
      ) == nil)

    await claims.release(Self.identifier)
    #expect(
      await discovery(root, claims: claims).discoverSessionIdentifier(
        workingDirectoryPath: "/Users/test/app",
        since: launchedAt,
        timeout: .seconds(1)
      ) == Self.identifier)
  }

  @Test("A rollout written after a later launch, by a session begun before it, is not taken (#144)")
  func sessionBegunBeforeTheLaunchIsNotTaken() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // A pane started a minute ago in the same repository, and nobody wrote to it until now: its
    // rollout is written after this launch, but its session began long before.
    let launchedAt = Date()
    try writeRollout(
      in: day, cwd: "/Users/test/app", createdAt: launchedAt.addingTimeInterval(1),
      startedAt: launchedAt.addingTimeInterval(-60))

    let found = await discovery(root).discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: launchedAt,
      timeout: .milliseconds(100)
    )
    #expect(found == nil)
  }

  @Test("A rollout two waiting panes could have written goes to neither, until one is out")
  func ambiguousRolloutGoesToNeither() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let discovery = discovery(root, claims: CodexSessionClaims())
    // Two panes started a second apart in the same repository, both still waiting.
    let first = CodexLaunch(workingDirectoryPath: "/Users/test/app", launchedAt: Date())
    let second = CodexLaunch(
      workingDirectoryPath: "/Users/test/app", launchedAt: first.launchedAt.addingTimeInterval(1))
    await discovery.beginWaiting(first)
    await discovery.beginWaiting(second)
    // Minutes later, someone writes to one of them.
    try writeRollout(
      in: day, cwd: "/Users/test/app", createdAt: second.launchedAt.addingTimeInterval(300),
      startedAt: second.launchedAt.addingTimeInterval(0.5))

    #expect(await discovery.discoverSessionIdentifier(for: first, timeout: .zero) == nil)
    #expect(await discovery.discoverSessionIdentifier(for: second, timeout: .zero) == nil)

    // The first pane learnt its session another way — its hook — or ended: the rollout can only
    // be the second one's now.
    await discovery.endWaiting(first)
    #expect(
      await discovery.discoverSessionIdentifier(for: second, timeout: .zero) == Self.identifier)
  }

  @Test("A pane left silent for an hour does not stop a pane launched since from finding its own")
  func silentPaneDoesNotStandInTheWay() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let discovery = discovery(root, claims: CodexSessionClaims())
    let later = CodexLaunch(workingDirectoryPath: "/Users/test/app", launchedAt: Date())
    // Launched an hour before in the same repository, and never written to: still waiting.
    let silent = CodexLaunch(
      workingDirectoryPath: "/Users/test/app",
      launchedAt: later.launchedAt.addingTimeInterval(-3600))
    await discovery.beginWaiting(silent)
    await discovery.beginWaiting(later)
    try writeRollout(
      in: day, cwd: "/Users/test/app", createdAt: later.launchedAt.addingTimeInterval(120),
      startedAt: later.launchedAt.addingTimeInterval(0.5))

    #expect(await discovery.discoverSessionIdentifier(for: silent, timeout: .zero) == nil)
    #expect(
      await discovery.discoverSessionIdentifier(for: later, timeout: .zero) == Self.identifier)
  }

  @Test("A pane waiting in another folder does not stand in the way")
  func waitingElsewhereDoesNotMatter() async throws {
    let (day, root) = try makeSessionsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let discovery = discovery(root, claims: CodexSessionClaims())
    let launch = CodexLaunch(workingDirectoryPath: "/Users/test/app", launchedAt: Date())
    let elsewhere = CodexLaunch(
      workingDirectoryPath: "/Users/test/other", launchedAt: launch.launchedAt)
    await discovery.beginWaiting(launch)
    await discovery.beginWaiting(elsewhere)
    try writeRollout(
      in: day, cwd: "/Users/test/app", createdAt: launch.launchedAt.addingTimeInterval(120),
      startedAt: launch.launchedAt.addingTimeInterval(0.5))

    #expect(
      await discovery.discoverSessionIdentifier(for: launch, timeout: .zero) == Self.identifier)
  }

  @Test("The watch slows down after its first period, up to the slowest pace")
  func watchSlowsDown() {
    let discovery = CodexRolloutSessionDiscovery(
      sessionsDirectory: URL(fileURLWithPath: "/nonexistent"), pollInterval: .milliseconds(500),
      briskPeriod: .seconds(30), slowestInterval: .seconds(5))
    #expect(discovery.interval(after: .seconds(10)) == .milliseconds(500))
    #expect(discovery.interval(after: .seconds(31)) == .seconds(1))
    #expect(discovery.interval(after: .seconds(61)) == .seconds(2))
    #expect(discovery.interval(after: .seconds(3600)) == .seconds(5))
  }

  @Test("A missing sessions directory times out instead of failing")
  func missingDirectory() async {
    let discovery = CodexRolloutSessionDiscovery(
      sessionsDirectory: URL(fileURLWithPath: "/nonexistent/codex/sessions"),
      pollInterval: .milliseconds(10)
    )
    let found = await discovery.discoverSessionIdentifier(
      workingDirectoryPath: "/Users/test/app",
      since: Date(),
      timeout: .milliseconds(50)
    )
    #expect(found == nil)
  }
}
