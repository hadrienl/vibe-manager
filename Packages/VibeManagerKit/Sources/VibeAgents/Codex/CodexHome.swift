import Foundation

/// Where the Codex CLI keeps its state: `$CODEX_HOME`, or `~/.codex` when it is unset.
///
/// Both the model cache and the session rollouts live there, so guessing `~/.codex` for a
/// user who moved their Codex home would read an empty directory and silently lose the
/// resume identifier.
public enum CodexHome {
  public static func directory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
    if let resolved = resolvedOverride(environment["CODEX_HOME"], home: home) {
      return URL(fileURLWithPath: resolved, isDirectory: true)
    }
    return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(
      ".codex", isDirectory: true)
  }

  /// An absolute or tilde prefixed `CODEX_HOME`, or `nil` when it cannot be resolved.
  ///
  /// A relative value is meaningless for a process this application starts elsewhere, and
  /// forwarding one would make the CLI write its sessions under a directory this code does
  /// not watch — a resume that silently never works. Such a value is dropped instead, by
  /// `sanitized(environment:)`, so both sides agree on `~/.codex`.
  public static func resolvedOverride(_ value: String?, home: String) -> String? {
    guard let value, !value.isEmpty else { return nil }
    if value.hasPrefix("/") { return value }
    if value == "~" { return home }
    if value.hasPrefix("~/") { return home + value.dropFirst(1) }
    return nil
  }

  /// Removes a `CODEX_HOME` this application cannot honour, so the CLI and the session
  /// discovery always read the same directory.
  public static func sanitized(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = environment
    let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
    guard let configured = environment["CODEX_HOME"] else { return environment }
    guard let resolved = resolvedOverride(configured, home: home) else {
      environment["CODEX_HOME"] = nil
      return environment
    }
    environment["CODEX_HOME"] = resolved
    return environment
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
