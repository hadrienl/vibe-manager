import Foundation

public enum ClaudeCodeHome {
  static let overrideKey = "CLAUDE_CONFIG_DIR"

  public static func directory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    AgentHomeDirectory.directory(
      overrideKey: overrideKey,
      defaultComponent: ".claude",
      environment: environment
    )
  }

  public static func sanitized(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    AgentHomeDirectory.sanitized(overrideKey: overrideKey, environment: environment)
  }

  /// Where the CLI caches the model catalog of the signed in account.
  public static func modelCatalogDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    directory(environment: environment)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("model-catalog", isDirectory: true)
  }
}
