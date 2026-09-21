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
public struct ClaudeCodeTranscriptWatcher: ClaudeCodeTranscriptWatching {
  private let projectsDirectory: URL
  private let pollInterval: Duration

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pollInterval: Duration = .milliseconds(500)
  ) {
    self.init(
      projectsDirectory: ClaudeCodeHome.projectsDirectory(environment: environment),
      pollInterval: pollInterval
    )
  }

  public init(projectsDirectory: URL, pollInterval: Duration = .milliseconds(500)) {
    self.projectsDirectory = projectsDirectory
    self.pollInterval = pollInterval
  }

  public func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    // The deadline and the sleeps are read from the same clock, so a timeout always expires.
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let name = "\(identifier).jsonl"

    while !Task.isCancelled {
      if transcriptExists(named: name) { return true }
      guard ContinuousClock.now < deadline else { return false }
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return false
      }
    }
    return false
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
