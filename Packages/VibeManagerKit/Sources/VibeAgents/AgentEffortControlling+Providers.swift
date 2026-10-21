import Foundation
import VibeApplication

/// Claude Code takes `--effort` at launch and `/effort` once it runs, and says nowhere which level
/// is in force: what the application gave it is all that is known, its default otherwise.
extension ClaudeCodeAgentProvider: AgentEffortControlling {
  /// As `claude --help` lists them in 2.1.306, for every model.
  static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

  public func effortLevels(modelID: String?) async -> [String] { Self.effortLevels }

  public var offersDefaultEffort: Bool { true }

  public func effortReport(resumeIdentifier: String?, since: Date) async -> AgentEffortReport {
    AgentEffortReport()
  }

  public func effortChange(to level: String?) -> AgentEffortChange? {
    // `default` puts the session back on the level of Claude Code's settings.
    .command("/effort \(level.flatMap(AgentEffortLevel.argument) ?? "default")")
  }
}

/// Codex says its level at every turn, and takes another one through its `/model` panel.
extension CodexAgentProvider: AgentEffortControlling {
  /// When the model cache lists none: the levels Codex has long had.
  static let fallbackEffortLevels = ["minimal", "low", "medium", "high", "xhigh"]

  public func effortLevels(modelID: String?) async -> [String] {
    guard let model = modelID ?? effortReader.configuredReport().modelID else {
      return Self.fallbackEffortLevels
    }
    let levels = await catalog.effortLevels(modelID: model)
    return levels.isEmpty ? Self.fallbackEffortLevels : levels
  }

  public var offersDefaultEffort: Bool { false }

  public func effortReport(resumeIdentifier: String?, since: Date) async -> AgentEffortReport {
    effortReader.report(resumeIdentifier: resumeIdentifier, since: since)
  }

  public func effortChange(to level: String?) -> AgentEffortChange? {
    guard let level = level.flatMap(AgentEffortLevel.argument) else { return nil }
    return .panel(opening: "/model", driver: CodexEffortPanel(level: level))
  }
}
