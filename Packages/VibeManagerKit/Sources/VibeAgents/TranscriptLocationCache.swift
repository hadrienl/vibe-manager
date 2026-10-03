import Foundation
import VibeApplication

/// Where each conversation's transcripts were found, so that a later look only checks what can
/// have changed (#255). One instance, made by the composition and given to the conversation view
/// and to the branch report alike (#276).
///
/// A Claude Code transcript never moves to another folder: once found, one `stat` says it is still
/// there. A Codex conversation resumed another day starts a new rollout in that day's folder, and
/// the folders of the days before never get one: only the last day listed and today are listed
/// again. Bounded: an entry evicted is rebuilt by the full look, which it only spares.
public final class TranscriptLocationCache: @unchecked Sendable {
  /// How many conversations are remembered.
  static let capacity = 256

  let locator: AgentTranscriptLocator
  /// How long a transcript looked for and not found is not looked for again: the projects are
  /// not listed at every look while its agent has not written it yet.
  private let missRetry: TimeInterval
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var claude: [String: URL] = [:]
  private var claudeMissed: [String: Date] = [:]
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
    missRetry: TimeInterval = 2,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.locator = locator
    self.missRetry = missRetry
    self.now = now
  }

  /// The main transcript of a Claude Code conversation: where it was found last time, else where
  /// Claude Code names the folder after the working directory, else wherever a look through every
  /// project finds it. Its sub-agents' files are not looked for. The look through every project is
  /// not made again for `missRetry` after it found nothing; the working directory's folder is.
  public func claudeTranscript(for identifier: String, workingDirectory: String?) -> URL? {
    let manager = FileManager.default
    let moment = now()
    let (known, missed) = lock.withLock { (claude[identifier], claudeMissed[identifier]) }
    if let known, manager.fileExists(atPath: known.path) {
      lock.withLock { touch("claude:\(identifier)") }
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
    if known == nil, let missed, moment.timeIntervalSince(missed) < missRetry { return nil }
    let folders = Signposts.interval("transcripts.list") { locator.list(locator.claudeProjects) }
    guard
      let found = (folders ?? []).lazy.map({ $0.appendingPathComponent(name) })
        .first(where: { manager.fileExists(atPath: $0.path) })
    else {
      lock.withLock {
        claude[identifier] = nil
        claudeMissed[identifier] = moment
        touch("claude:\(identifier)")
      }
      return nil
    }
    remember(claude: found, for: identifier)
    return found
  }

  /// Every rollout of a Codex conversation: the days listed before are not listed again, but for
  /// the last one, and the days since. A rollout deleted since is not given back.
  public func codexRollouts(for identifier: String, since created: Date) -> [URL] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let moment = now()
    let known = lock.withLock { codex[identifier] }
    var first = created.addingTimeInterval(-86_400)
    // The day before the last one listed, in case the clock or the time zone went back.
    if let known, let resumed = calendar.date(byAdding: .day, value: -1, to: known.listedThrough),
      resumed > calendar.startOfDay(for: first)
    {
      first = resumed
    }
    let manager = FileManager.default
    var found = (known?.found ?? []).filter { manager.fileExists(atPath: $0.path) }
    found.formUnion(
      Signposts.interval("transcripts.list") {
        locator.codexRollouts(for: identifier, fromDay: first, until: moment)
      })
    let rollouts = CodexRollouts(found: found, listedThrough: calendar.startOfDay(for: moment))
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

  private func remember(claude url: URL, for identifier: String) {
    lock.withLock {
      claude[identifier] = url
      claudeMissed[identifier] = nil
      touch("claude:\(identifier)")
    }
  }

  /// Moves an entry to the most recent end — a hit counts as a use — and lets the oldest go past
  /// the capacity. Under the lock.
  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > Self.capacity {
      let evicted = order.removeFirst()
      if evicted.hasPrefix("claude:") {
        let identifier = String(evicted.dropFirst(7))
        claude[identifier] = nil
        claudeMissed[identifier] = nil
      } else {
        codex[String(evicted.dropFirst(6))] = nil
      }
    }
  }
}
