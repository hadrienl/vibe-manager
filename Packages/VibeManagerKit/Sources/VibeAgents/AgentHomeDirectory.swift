import Foundation

/// Resolves the directory an agent CLI keeps its state in, from the variable that overrides it.
///
/// Every CLI has one: `CODEX_HOME`, `CLAUDE_CONFIG_DIR`. They share the same three problems —
/// a tilde that only a shell expands, a relative value that means nothing to a process started
/// from the Finder, and the need for the application to read the *same* directory the CLI
/// writes to. Resolving them in one place keeps the agent and the reader from disagreeing.
public enum AgentHomeDirectory {
  /// The absolute path an override denotes, or `nil` when it denotes nothing usable.
  ///
  /// A relative value is rejected rather than resolved against the current directory: the
  /// application's working directory has no relationship with the one the user meant.
  public static func resolvedOverride(_ value: String?, home: String) -> String? {
    guard let value, !value.isEmpty else { return nil }
    if value.hasPrefix("/") { return value }
    if value == "~" { return home }
    if value.hasPrefix("~/") { return home + value.dropFirst(1) }
    return nil
  }

  public static func home(in environment: [String: String]) -> String {
    environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
  }

  public static func directory(
    overrideKey: String,
    defaultComponent: String,
    environment: [String: String]
  ) -> URL {
    let home = home(in: environment)
    if let resolved = resolvedOverride(environment[overrideKey], home: home) {
      return URL(fileURLWithPath: resolved, isDirectory: true)
    }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(defaultComponent, isDirectory: true)
  }

  /// Replaces the override with its absolute form, or drops it when it cannot be resolved.
  ///
  /// Forwarding a value the CLI would interpret differently than the reader does produces a
  /// session that is silently never found again, which is worse than not forwarding it.
  public static func sanitized(
    overrideKey: String,
    environment: [String: String]
  ) -> [String: String] {
    var environment = environment
    guard let configured = environment[overrideKey] else { return environment }
    guard let resolved = resolvedOverride(configured, home: home(in: environment)) else {
      environment[overrideKey] = nil
      return environment
    }
    environment[overrideKey] = resolved
    return environment
  }
}
