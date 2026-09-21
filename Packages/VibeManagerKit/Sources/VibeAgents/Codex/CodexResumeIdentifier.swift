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

/// Finds the identifier of the Codex session a terminal just started.
public protocol CodexSessionDiscovering: Sendable {
  /// Identifier of the session created after `since` for that working directory, or `nil`
  /// when none appears before the deadline.
  func discoverSessionIdentifier(
    workingDirectoryPath: String,
    since: Date,
    timeout: Duration
  ) async -> String?
}

/// Watches the rollout files Codex writes under `$CODEX_HOME/sessions`.
///
/// A session records `session_id` and `cwd` in the very first line of its rollout file, which
/// makes it the one identifier source that does not depend on how the interface renders.
/// Matching uses the working directory and the launch time, and keeps the *oldest* rollout
/// created after the launch: the newest one may belong to a pane started a moment later in
/// the same repository, which would give two sessions the same identifier.
public struct CodexRolloutSessionDiscovery: CodexSessionDiscovering {
  /// The first line carries the session metadata and the base instructions, which are large
  /// but bounded. A file without a newline within that window is simply not written yet.
  static let maximumFirstLineByteCount = 4 * 1024 * 1024
  /// A rollout file is created a moment before or after the application notes the launch
  /// date, and file timestamps have their own granularity. Kept small: every extra second
  /// widens the window in which a previous session can be mistaken for this one.
  static let creationTolerance: TimeInterval = 2

  private let sessionsDirectory: URL
  private let pollInterval: Duration

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pollInterval: Duration = .milliseconds(500)
  ) {
    self.init(
      sessionsDirectory: CodexHome.sessionsDirectory(environment: environment),
      pollInterval: pollInterval
    )
  }

  public init(sessionsDirectory: URL, pollInterval: Duration = .milliseconds(500)) {
    self.sessionsDirectory = sessionsDirectory
    self.pollInterval = pollInterval
  }

  public func discoverSessionIdentifier(
    workingDirectoryPath: String,
    since: Date,
    timeout: Duration
  ) async -> String? {
    // The deadline and the sleeps are read from the same clock: a timeout measured against
    // an injected date while sleeping against the real one would never expire.
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let workingDirectory = Self.canonicalPath(workingDirectoryPath)

    while !Task.isCancelled {
      if let identifier = identifier(matching: workingDirectory, since: since) {
        return identifier
      }
      guard ContinuousClock.now < deadline else { return nil }
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return nil
      }
    }
    return nil
  }

  private func identifier(matching workingDirectory: String, since: Date) -> String? {
    let candidates = rollouts(since: since)
    for candidate in candidates {
      guard let meta = sessionMeta(at: candidate.url) else { continue }
      guard Self.canonicalPath(meta.cwd) == workingDirectory else { continue }
      guard UUID(uuidString: meta.sessionID) != nil else { continue }
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

    let floor = since.addingTimeInterval(-Self.creationTolerance)
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
    return SessionMeta(sessionID: sessionID, cwd: cwd)
  }

  /// `/tmp` and `/private/tmp` are the same directory; a session must not be missed over it.
  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private struct SessionMeta {
    let sessionID: String
    let cwd: String
  }

  private struct RolloutRecord: Decodable {
    let payload: Payload?

    struct Payload: Decodable {
      let sessionID: String?
      let id: String?
      let cwd: String?

      private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case id
        case cwd
      }
    }
  }
}
