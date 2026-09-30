import Foundation

/// Evidence that the conversation a launch assigned an identifier to really exists.
public protocol ClaudeCodeTranscriptWatching: Sendable {
  /// `true` once the CLI has written the conversation down, `false` if nothing appears
  /// before the deadline.
  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool
}

/// Watches the transcripts the CLI writes under `$CLAUDE_CONFIG_DIR/projects`.
///
/// A conversation is written to `<projects>/<escaped working directory>/<session id>.jsonl`
/// as soon as it holds a first exchange. The identifier is a UUID this app generated, so its
/// file name is unique across the whole tree and the directory it lands in — whose escaping
/// rule is the CLI's own business — never has to be guessed.
///
/// The file can take a long time to come: the CLI writes it with the first message, and a session
/// started without a prompt waits for the user. Looked for often at first, when a prompt given at
/// launch makes it appear within a second or two, and less and less often afterwards: a session
/// nobody writes to must not keep the disk busy for hours (#138).
public struct ClaudeCodeTranscriptWatcher: ClaudeCodeTranscriptWatching {
  /// How long the watch keeps its first pace before slowing down.
  public static let briskPeriod: Duration = .seconds(30)
  /// The longest pause between two looks, once slowed down.
  public static let slowestInterval: Duration = .seconds(5)

  private let projectsDirectory: URL
  private let pollInterval: Duration
  private let briskPeriod: Duration
  private let slowestInterval: Duration

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pollInterval: Duration = .milliseconds(500)
  ) {
    self.init(
      projectsDirectory: ClaudeCodeHome.projectsDirectory(environment: environment),
      pollInterval: pollInterval
    )
  }

  public init(
    projectsDirectory: URL,
    pollInterval: Duration = .milliseconds(500),
    briskPeriod: Duration = ClaudeCodeTranscriptWatcher.briskPeriod,
    slowestInterval: Duration = ClaudeCodeTranscriptWatcher.slowestInterval
  ) {
    self.projectsDirectory = projectsDirectory
    self.pollInterval = pollInterval
    self.briskPeriod = briskPeriod
    self.slowestInterval = max(slowestInterval, pollInterval)
  }

  public func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    // The deadline and the sleeps are read from the same clock, so a timeout always expires.
    let start = ContinuousClock.now
    let deadline = start.advanced(by: timeout)
    let name = "\(identifier).jsonl"

    while !Task.isCancelled {
      if transcriptExists(named: name) { return true }
      let now = ContinuousClock.now
      guard now < deadline else { return false }
      do {
        // Nothing hangs on the exact moment: the system may group this wake with others.
        let pause = min(interval(after: now - start), deadline - now)
        try await Task.sleep(for: pause, tolerance: pause / 2)
      } catch {
        return false
      }
    }
    return false
  }

  /// The pause before the next look, once the watch has lasted `elapsed`: the first pace during
  /// the brisk period, then twice as long for every further brisk period, up to the slowest.
  func interval(after elapsed: Duration) -> Duration {
    guard elapsed >= briskPeriod, briskPeriod > .zero else { return pollInterval }
    let periods = min(Int(elapsed / briskPeriod), 16)
    return min(pollInterval * (1 << periods), slowestInterval)
  }

  private func transcriptExists(named name: String) -> Bool {
    let manager = FileManager.default
    guard
      let projects = try? manager.contentsOfDirectory(
        at: projectsDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }

    for project in projects {
      let transcript = project.appendingPathComponent(name, isDirectory: false)
      if manager.fileExists(atPath: transcript.path) { return true }
    }
    return false
  }
}
