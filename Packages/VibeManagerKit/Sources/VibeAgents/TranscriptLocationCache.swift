import Foundation
import VibeApplication

/// Where each conversation's transcripts were found, so that a later look only checks what can
/// have changed (#255).
///
/// A Claude Code transcript never moves to another folder: once found, one `stat` says it is still
/// there. A Codex conversation resumed another day starts a new rollout in that day's folder, and
/// the folders of the days before never get one: only the last day listed and today are listed
/// again. Bounded: an entry evicted is rebuilt by the full look, which it only spares.
public final class TranscriptLocationCache: @unchecked Sendable {
  public static let shared = TranscriptLocationCache()

  /// How many conversations are remembered.
  static let capacity = 256

  private let locator: AgentTranscriptLocator
  private let list: @Sendable (URL) -> [URL]?
  private let lock = NSLock()
  private var claude: [String: URL] = [:]
  private var codex: [String: CodexRollouts] = [:]
  /// Oldest first, both kinds together.
  private var order: [String] = []

  private struct CodexRollouts {
    var found: Set<URL>
    /// The last day listed, at its start: from the day before it, the next look lists again.
    var listedThrough: Date
  }

  public init(
    locator: AgentTranscriptLocator = AgentTranscriptLocator(),
    list: @escaping @Sendable (URL) -> [URL]? = {
      try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }
  ) {
    self.locator = locator
    self.list = list
  }

  /// The main transcript of a Claude Code conversation: where it was found last time, else where
  /// Claude Code names the folder after the working directory, else wherever a look through every
  /// project finds it. Its sub-agents' files are not looked for.
  public func claudeTranscript(for identifier: String, workingDirectory: String?) -> URL? {
    let manager = FileManager.default
    if let known = lock.withLock({ claude[identifier] }), manager.fileExists(atPath: known.path) {
      return known
    }
    let name = "\(identifier).jsonl"
    if let workingDirectory {
      let direct = locator.claudeProjects
        .appendingPathComponent(Self.claudeFolderName(for: workingDirectory))
        .appendingPathComponent(name)
      if manager.fileExists(atPath: direct.path) {
        remember(claude: direct, for: identifier)
        return direct
      }
    }
    let folders = listed(locator.claudeProjects) ?? []
    guard
      let found = folders.lazy.map({ $0.appendingPathComponent(name) })
        .first(where: { manager.fileExists(atPath: $0.path) })
    else {
      lock.withLock { claude[identifier] = nil }
      return nil
    }
    remember(claude: found, for: identifier)
    return found
  }

  /// Every rollout of a Codex conversation: the days listed before are not listed again, but for
  /// the last one, and the days since.
  public func codexRollouts(for identifier: String, since created: Date, now: Date = Date())
    -> [URL]
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let firstDay = calendar.startOfDay(for: created.addingTimeInterval(-86_400))
    let today = calendar.startOfDay(for: now)
    let known = lock.withLock { codex[identifier] }
    var day = firstDay
    // The day before the last one listed, in case the clock or the time zone went back.
    if let known, let resumed = calendar.date(byAdding: .day, value: -1, to: known.listedThrough),
      resumed > firstDay
    {
      day = resumed
    }
    var found = known?.found ?? []
    while day <= today {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let folder = locator.codexSessions
        .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
        .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
      for file in listed(folder) ?? []
      where file.lastPathComponent.contains(identifier) && file.pathExtension == "jsonl" {
        found.insert(file)
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    let rollouts = CodexRollouts(found: found, listedThrough: today)
    lock.withLock {
      codex[identifier] = rollouts
      touch("codex:\(identifier)")
    }
    return Array(found)
  }

  /// The folder Claude Code keeps a working directory's conversations in: its path, every
  /// character but a letter or a digit made a dash.
  static func claudeFolderName(for workingDirectory: String) -> String {
    String(
      workingDirectory.unicodeScalars.map {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-"
      })
  }

  private func listed(_ folder: URL) -> [URL]? {
    Signposts.interval("transcripts.list") { list(folder) }
  }

  private func remember(claude url: URL, for identifier: String) {
    lock.withLock {
      claude[identifier] = url
      touch("claude:\(identifier)")
    }
  }

  /// Moves an entry to the most recent end, and lets the oldest go past the capacity. Under the
  /// lock.
  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > Self.capacity {
      let evicted = order.removeFirst()
      if evicted.hasPrefix("claude:") {
        claude[String(evicted.dropFirst(7))] = nil
      } else {
        codex[String(evicted.dropFirst(6))] = nil
      }
    }
  }
}
