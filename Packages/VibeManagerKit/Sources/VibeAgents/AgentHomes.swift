import Foundation

/// The configuration folders of the agents' extra accounts (#478), read by everything that looks
/// for a transcript. Each is known by its account's provider identifier: a conversation is looked
/// for in its own account's folder, as a folder copied to start an account holds the agent's
/// conversations too. Replaced as a whole when the accounts are saved.
public final class AgentHomes: @unchecked Sendable {
  private let lock = NSLock()
  private var claude: [String: URL] = [:]
  private var codex: [String: URL] = [:]

  public init() {}

  /// - Parameters:
  ///   - claudeHomes: the folders that hold `projects`, by their account's provider identifier.
  ///   - codexHomes: the folders that hold `sessions`, likewise.
  public func replace(claudeHomes: [String: URL], codexHomes: [String: URL]) {
    let claude = claudeHomes.mapValues {
      $0.appendingPathComponent("projects", isDirectory: true)
    }
    let codex = codexHomes.mapValues { $0.appendingPathComponent("sessions", isDirectory: true) }
    lock.withLock {
      self.claude = claude
      self.codex = codex
    }
  }

  var claudeProjects: [String: URL] { lock.withLock { claude } }
  var codexSessions: [String: URL] { lock.withLock { codex } }
}
