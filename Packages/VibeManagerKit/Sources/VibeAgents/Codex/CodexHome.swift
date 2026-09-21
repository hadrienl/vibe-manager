import Foundation

public enum CodexHome {
  static let overrideKey = "CODEX_HOME"

  public static func directory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    AgentHomeDirectory.directory(
      overrideKey: overrideKey,
      defaultComponent: ".codex",
      environment: environment
    )
  }

  public static func resolvedOverride(_ value: String?, home: String) -> String? {
    AgentHomeDirectory.resolvedOverride(value, home: home)
  }

  public static func sanitized(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    AgentHomeDirectory.sanitized(overrideKey: overrideKey, environment: environment)
  }

  public static func sessionsDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    directory(environment: environment).appendingPathComponent("sessions", isDirectory: true)
  }

  public static func modelsCacheURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    directory(environment: environment).appendingPathComponent("models_cache.json")
  }
}
