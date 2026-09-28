import Foundation
import VibeApplication

/// Reads a Codex session identifier from what the agent printed in the terminal.
///
/// Opportunistic by design: the layout of the terminal interface is not a contract, so this
/// extractor only recognises a well formed identifier on a line that names a session, and
/// gives up otherwise. `CodexRolloutSessionDiscovery` is the reliable source.
public struct CodexResumeIdentifierExtractor: AgentResumeIdentifierExtractor {
  public init() {}

  public func resumeIdentifier(in chunk: String) -> String? {
    for line in Self.stripANSI(chunk).split(whereSeparator: \.isNewline) {
      // A bare identifier is not enough: terminal output echoes the prompt, and a prompt can
      // very well contain a UUID that has nothing to do with this session.
      guard line.localizedCaseInsensitiveContains("session") else { continue }
      if let identifier = Self.firstIdentifier(in: line) { return identifier }
    }
    return nil
  }

  static func firstIdentifier(in line: Substring) -> String? {
    for candidate in line.split(whereSeparator: { !$0.isHexDigit && $0 != "-" }) {
      let value = String(candidate)
      guard value.count == 36, UUID(uuidString: value) != nil else { continue }
      return value
    }
    return nil
  }

  /// Removes CSI and OSC sequences so a coloured line is matched like a plain one.
  static func stripANSI(_ text: String) -> String {
    var output = String()
    output.reserveCapacity(text.count)

    var characters = Substring(text)
    while let escape = characters.firstIndex(of: "\u{1B}") {
      output.append(contentsOf: characters[characters.startIndex..<escape])
      var index = characters.index(after: escape)
      guard index < characters.endIndex else {
        characters = characters[characters.endIndex...]
        break
      }

      switch characters[index] {
      case "[":
        index = characters.index(after: index)
        while index < characters.endIndex, !characters[index].isANSIFinalByte {
          index = characters.index(after: index)
        }
        if index < characters.endIndex { index = characters.index(after: index) }
      case "]":
        // An operating system command runs until BEL or ST (ESC \).
        index = characters.index(after: index)
        while index < characters.endIndex, characters[index] != "\u{07}",
          characters[index] != "\u{1B}"
        {
          index = characters.index(after: index)
        }
        if index < characters.endIndex, characters[index] == "\u{1B}" {
          index = characters.index(after: index)
        }
        if index < characters.endIndex { index = characters.index(after: index) }
      default:
        index = characters.index(after: index)
      }
      characters = characters[index...]
    }

    output.append(contentsOf: characters)
    return output
  }
}

extension Character {
  fileprivate var isANSIFinalByte: Bool {
    guard let ascii = asciiValue else { return false }
    return ascii >= 0x40 && ascii <= 0x7E
  }
}

/// One launch of Codex, as the discovery of its session sees it.
public struct CodexLaunch: Hashable, Sendable {
  public let id: UUID
  public let workingDirectoryPath: String
  /// Taken once the process is started: its session cannot have begun much before.
  public let launchedAt: Date

  public init(id: UUID = UUID(), workingDirectoryPath: String, launchedAt: Date) {
    self.id = id
    self.workingDirectoryPath = workingDirectoryPath
    self.launchedAt = launchedAt
  }
}

/// The Codex sessions already attributed to a pane in this process, and the launches still waiting
/// for theirs.
///
/// Two panes started in the same repository see the same rollout files. Creation time alone cannot
/// tell them apart — a slow pane would happily adopt the session of the pane that started just
/// before it — so a session is claimed once and never handed out twice, and one that could belong
/// to either of two waiting launches is handed to neither (#144).
public actor CodexSessionClaims {
  public static let shared = CodexSessionClaims()

  /// How much earlier than the launch it was taken for a session may say it began. The launch is
  /// dated once the process is started, a moment after it really was, and a session begins with
  /// the process: this covers the gap, with a wide margin.
  public static let startTolerance: TimeInterval = 5

  private struct Waiting {
    let directory: String
    let launchedAt: Date
  }

  private var claimed: Set<String> = []
  private var waiting: [UUID: Waiting] = [:]

  public init() {}

  /// Claims a session for the caller. `false` means another pane already owns it.
  public func claim(_ identifier: String) -> Bool {
    claimed.insert(identifier).inserted
  }

  /// Claims a session found on disk for `launch`, only when it can be no other launch's.
  ///
  /// - Parameters:
  ///   - startedAt: when the session began — at the start of its process, not with the first
  ///     message that wrote its rollout.
  ///   - directory: the session's working directory, canonical.
  /// - Returns: `false` when the session is already claimed, began before `launch`, or could just
  ///   as well belong to another launch still waiting in the same directory.
  public func claim(
    _ identifier: String, startedAt: Date, directory: String, for launch: CodexLaunch
  ) -> Bool {
    guard !claimed.contains(identifier) else { return false }
    let floor = { (launchedAt: Date) in launchedAt.addingTimeInterval(-Self.startTolerance) }
    guard startedAt >= floor(launch.launchedAt) else { return false }
    let rivals = waiting.filter { id, other in
      id != launch.id && other.directory == directory && startedAt >= floor(other.launchedAt)
    }
    guard rivals.isEmpty else { return false }
    claimed.insert(identifier)
    return true
  }

  public func release(_ identifier: String) {
    claimed.remove(identifier)
  }

  public func isClaimed(_ identifier: String) -> Bool {
    claimed.contains(identifier)
  }

  /// `launch` waits for its session, in `directory` (canonical): until it ends, a session that
  /// began after it in that directory may be its own.
  public func beginWaiting(_ launch: CodexLaunch, directory: String) {
    waiting[launch.id] = Waiting(directory: directory, launchedAt: launch.launchedAt)
  }

  public func endWaiting(_ launch: CodexLaunch) {
    waiting[launch.id] = nil
  }
}

public protocol CodexSessionDiscovering: Sendable {
  /// Identifier of the session `launch` started, or `nil` when none that can only be its own
  /// appears before the deadline.
  func discoverSessionIdentifier(for launch: CodexLaunch, timeout: Duration) async -> String?
  /// `launch` is waiting for its session, however it will learn it: another launch must not take
  /// a session that may be this one's.
  func beginWaiting(_ launch: CodexLaunch) async
  /// `launch` knows its session, or has ended.
  func endWaiting(_ launch: CodexLaunch) async
  /// A session learned some other way — the agent's own hook, its terminal — is taken: no other
  /// launch may be handed it.
  func claim(_ identifier: String) async
}

extension CodexSessionDiscovering {
  public func beginWaiting(_ launch: CodexLaunch) async {}
  public func endWaiting(_ launch: CodexLaunch) async {}
  public func claim(_ identifier: String) async {}
}

/// Watches the rollout files Codex writes under `$CODEX_HOME/sessions`.
///
/// A session records `session_id`, `cwd` and the instant it began in the very first line of its
/// rollout file, which makes it the one identifier source that does not depend on how the interface
/// renders. Codex begins the session when it starts but writes the file only with the first
/// message (checked with 0.157.1), minutes later if nobody writes to it: the file's date says when
/// the user spoke, the first line says which launch it came from.
///
/// Matching uses the working directory, the launch time, and the launches still waiting in that
/// directory (`CodexSessionClaims`): a rollout that could belong to another of them is taken by
/// none. Among those that remain, the *oldest* created after the launch is kept.
public struct CodexRolloutSessionDiscovery: CodexSessionDiscovering {
  /// The first line carries the session metadata and the base instructions, which are large
  /// but bounded. A file without a newline within that window is simply not written yet.
  static let maximumFirstLineByteCount = 4 * 1024 * 1024
  /// How long the watch keeps its first pace before slowing down: a prompt given at launch writes
  /// the rollout within a few seconds.
  public static let briskPeriod: Duration = .seconds(30)
  /// The longest pause between two looks, once slowed down.
  public static let slowestInterval: Duration = .seconds(5)

  private let sessionsDirectory: URL
  private let pollInterval: Duration
  private let briskPeriod: Duration
  private let slowestInterval: Duration
  private let claims: CodexSessionClaims

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pollInterval: Duration = .milliseconds(500),
    claims: CodexSessionClaims = .shared
  ) {
    self.init(
      sessionsDirectory: CodexHome.sessionsDirectory(environment: environment),
      pollInterval: pollInterval,
      claims: claims
    )
  }

  public init(
    sessionsDirectory: URL,
    pollInterval: Duration = .milliseconds(500),
    briskPeriod: Duration = CodexRolloutSessionDiscovery.briskPeriod,
    slowestInterval: Duration = CodexRolloutSessionDiscovery.slowestInterval,
    claims: CodexSessionClaims = .shared
  ) {
    self.sessionsDirectory = sessionsDirectory
    self.pollInterval = pollInterval
    self.briskPeriod = briskPeriod
    self.slowestInterval = max(slowestInterval, pollInterval)
    self.claims = claims
  }

  public func beginWaiting(_ launch: CodexLaunch) async {
    await claims.beginWaiting(launch, directory: Self.canonicalPath(launch.workingDirectoryPath))
  }

  public func endWaiting(_ launch: CodexLaunch) async {
    await claims.endWaiting(launch)
  }

  public func claim(_ identifier: String) async {
    _ = await claims.claim(identifier)
  }

  /// A launch of its own, for a caller that only knows where and when.
  public func discoverSessionIdentifier(
    workingDirectoryPath: String,
    since: Date,
    timeout: Duration
  ) async -> String? {
    await discoverSessionIdentifier(
      for: CodexLaunch(workingDirectoryPath: workingDirectoryPath, launchedAt: since),
      timeout: timeout)
  }

  public func discoverSessionIdentifier(for launch: CodexLaunch, timeout: Duration) async -> String?
  {
    // The deadline and the sleeps are read from the same clock: a timeout measured against
    // an injected date while sleeping against the real one would never expire.
    let start = ContinuousClock.now
    let deadline = start.advanced(by: timeout)
    let workingDirectory = Self.canonicalPath(launch.workingDirectoryPath)
    // A first line never changes once written: read once per file, not once per look.
    var metas: [URL: SessionMeta] = [:]

    while !Task.isCancelled {
      if let identifier = await identifier(matching: workingDirectory, for: launch, metas: &metas) {
        return identifier
      }
      let now = ContinuousClock.now
      guard now < deadline else { return nil }
      do {
        try await Task.sleep(for: min(interval(after: now - start), deadline - now))
      } catch {
        return nil
      }
    }
    return nil
  }

  /// The pause before the next look, once the watch has lasted `elapsed`: the first pace during
  /// the brisk period, then twice as long for every further brisk period, up to the slowest.
  func interval(after elapsed: Duration) -> Duration {
    guard elapsed >= briskPeriod, briskPeriod > .zero else { return pollInterval }
    let periods = min(Int(elapsed / briskPeriod), 16)
    return min(pollInterval * (1 << periods), slowestInterval)
  }

  private func identifier(
    matching workingDirectory: String, for launch: CodexLaunch, metas: inout [URL: SessionMeta]
  ) async -> String? {
    for candidate in rollouts(since: launch.launchedAt) {
      let meta: SessionMeta
      if let known = metas[candidate.url] {
        meta = known
      } else if let read = sessionMeta(at: candidate.url) {
        metas[candidate.url] = read
        meta = read
      } else {
        continue
      }
      guard Self.canonicalPath(meta.cwd) == workingDirectory else { continue }
      guard UUID(uuidString: meta.sessionID) != nil else { continue }
      // A session another pane already took, one that began before this launch, or one that
      // may be another waiting launch's is not ours, however well it matches.
      guard
        await claims.claim(
          meta.sessionID, startedAt: meta.startedAt ?? candidate.createdAt,
          directory: workingDirectory, for: launch)
      else { continue }
      return meta.sessionID
    }
    return nil
  }

  /// Rollout files created around or after the launch, oldest first.
  private func rollouts(since: Date) -> [(url: URL, createdAt: Date)] {
    let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionsDirectory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    // Strictly after the launch: a rollout created before it belongs to an earlier pane, and
    // admitting it would let a pane started second adopt the session of the pane started first.
    let floor = since
    var found: [(url: URL, createdAt: Date)] = []
    for case let url as URL in enumerator {
      // Rollouts are filed under year/month/day. A heavy user keeps years of them, so whole
      // folders that predate the launch are skipped instead of walked file by file.
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        if isEntirelyBefore(directory: url, floor: floor) { enumerator.skipDescendants() }
        continue
      }
      guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else {
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true,
        let createdAt = values.creationDate,
        createdAt >= floor
      else {
        continue
      }
      found.append((url, createdAt))
    }
    return found.sorted { $0.createdAt < $1.createdAt }
  }

  /// True when a `2026`, `2026/09` or `2026/09/21` folder is entirely older than `floor`.
  ///
  /// Only a folder that is *strictly* older is pruned, and only when the layout is the dated
  /// one; anything unexpected is walked, so a change in how Codex files its sessions costs
  /// time, never a missed identifier. The comparison is deliberately loose by one day on each
  /// side, since the folder names carry no time zone.
  func isEntirelyBefore(directory: URL, floor: Date) -> Bool {
    let root = sessionsDirectory.standardizedFileURL.pathComponents
    let components = directory.standardizedFileURL.pathComponents
    guard components.count > root.count, Array(components.prefix(root.count)) == root else {
      return false
    }

    let dated = components.dropFirst(root.count).compactMap { component -> Int? in
      component.allSatisfy(\.isNumber) ? Int(component) : nil
    }
    guard dated.count == components.count - root.count, !dated.isEmpty, dated.count <= 3 else {
      return false
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let limit = calendar.dateComponents([.year, .month, .day], from: floor - 86_400)
    guard let year = limit.year, let month = limit.month, let day = limit.day else { return false }

    let bound = [year, month, day]
    for (value, reference) in zip(dated, bound) {
      if value < reference { return true }
      if value > reference { return false }
    }
    return false
  }

  /// Reads only the first line of a rollout, and only up to a bounded size.
  private func sessionMeta(at url: URL) -> SessionMeta? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    var buffer = Data()
    while buffer.count < Self.maximumFirstLineByteCount {
      guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
      buffer.append(chunk)
      if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        return decodeMeta(from: buffer[buffer.startIndex..<newline])
      }
    }
    return nil
  }

  private func decodeMeta(from data: Data) -> SessionMeta? {
    guard let record = try? JSONDecoder().decode(RolloutRecord.self, from: data),
      let payload = record.payload,
      let sessionID = payload.sessionID ?? payload.id,
      let cwd = payload.cwd
    else {
      return nil
    }
    return SessionMeta(
      sessionID: sessionID, cwd: cwd, startedAt: payload.timestamp.flatMap(Self.date(from:)))
  }

  /// `2026-09-28T00:57:54.460Z`, with or without its fraction of a second.
  static func date(from text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  /// `/tmp` and `/private/tmp` are the same directory; a session must not be missed over it.
  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  struct SessionMeta {
    let sessionID: String
    let cwd: String
    /// When the session began — with its process. `nil` in a first line that does not say.
    let startedAt: Date?
  }

  private struct RolloutRecord: Decodable {
    let payload: Payload?

    struct Payload: Decodable {
      let sessionID: String?
      let id: String?
      let cwd: String?
      let timestamp: String?

      private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case id
        case cwd
        case timestamp
      }
    }
  }
}
