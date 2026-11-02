import Foundation

/// The configuration folders of the agents' extra accounts (#478), read by everything that looks
/// for a transcript: a conversation is named by a UUID, so looking through every folder of its
/// CLI cannot find another's. Replaced as a whole when the accounts are saved.
public final class AgentHomes: @unchecked Sendable {
  private let lock = NSLock()
  private var claude: [URL] = []
  private var codex: [URL] = []

  public init() {}

  /// - Parameters:
  ///   - claudeHomes: the folders that hold `projects`.
  ///   - codexHomes: the folders that hold `sessions`.
  public func replace(claudeHomes: [URL], codexHomes: [URL]) {
    let claude = claudeHomes.map { $0.appendingPathComponent("projects", isDirectory: true) }
    let codex = codexHomes.map { $0.appendingPathComponent("sessions", isDirectory: true) }
    lock.withLock {
      self.claude = claude
      self.codex = codex
    }
  }

  var claudeProjects: [URL] { lock.withLock { claude } }
  var codexSessions: [URL] { lock.withLock { codex } }
}
