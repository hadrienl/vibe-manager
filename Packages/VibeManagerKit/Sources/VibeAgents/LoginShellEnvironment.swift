import Foundation
import VibeApplication

/// The environment the user's own shell ends up with, asked once and kept.
///
/// An application launched from the Finder inherits the environment of `launchd`, whose `PATH`
/// is `/usr/bin:/bin:/usr/sbin:/sbin`. Finding the agent's binary through a login shell is not
/// enough: the agent then runs, but every command it starts — `npm`, `node`, `codex` — looks
/// them up in that bare `PATH` and fails. The shell is interactive as well as a login one because
/// that is where most users put their `PATH` and their version managers: `~/.zshrc`.
public protocol ShellEnvironmentSource: Sendable {
  /// `nil` when the shell could not be asked or never answered: the caller keeps what it has.
  func environment() async -> [String: String]?
}

public actor LoginShellEnvironment: ShellEnvironmentSource {
  /// What the agent takes from the shell rather than from the application. Anything else keeps
  /// its inherited value: the application resolves the agents' configuration folders from its
  /// own environment, and the agent must agree with it on where they are.
  public static let adoptedKeys: Set<String> = ["PATH", "NVM_DIR"]

  /// Printed before the environment, so whatever the user's configuration writes on the
  /// standard output while it loads is never read as a variable.
  static let marker = "__VIBE_MANAGER_SHELL_ENVIRONMENT__"

  private let inherited: [String: String]
  private let probe: any ProcessProbe
  private let timeout: Duration
  private var resolution: Task<[String: String]?, Never>?

  public init(
    inherited: [String: String] = ProcessInfo.processInfo.environment,
    probe: any ProcessProbe,
    timeout: Duration = .seconds(10)
  ) {
    self.inherited = inherited
    self.probe = probe
    self.timeout = timeout
  }

  /// Starts asking now, so the first launch does not pay for a shell sourcing its configuration.
  public nonisolated func warmUp() {
    Task { _ = await environment() }
  }

  public func environment() async -> [String: String]? {
    if let resolution { return await resolution.value }

    let task = Task { [inherited, probe, timeout] in
      await Self.resolve(inherited: inherited, probe: probe, timeout: timeout)
    }
    resolution = task
    let resolved = await task.value
    // A shell that did not answer this time may answer the next: only an answer is kept.
    if resolved == nil { resolution = nil }
    return resolved
  }

  private static func resolve(
    inherited: [String: String],
    probe: any ProcessProbe,
    timeout: Duration
  ) async -> [String: String]? {
    let shell = inherited["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    guard
      let result = try? await probe.run(
        executablePath: shell,
        arguments: ["-l", "-i", "-c", "printf '%s' \(marker); /usr/bin/env -0"],
        environment: AgentEnvironmentPolicy.environment(base: inherited),
        workingDirectoryPath: nil,
        timeout: timeout
      ),
      !result.didTimeOut, result.exitCode == 0
    else { return nil }
    return parse(result.standardOutput)
  }

  /// Reads the variables `env -0` printed after the marker, keeping the adopted ones only.
  static func parse(_ output: String) -> [String: String]? {
    guard let start = output.range(of: marker, options: .backwards) else { return nil }
    var environment: [String: String] = [:]
    for entry in output[start.upperBound...].split(separator: "\0") {
      guard let separator = entry.firstIndex(of: "=") else { continue }
      let key = String(entry[..<separator])
      guard adoptedKeys.contains(key) else { continue }
      environment[key] = String(entry[entry.index(after: separator)...])
    }
    // Without a `PATH` the shell has not said anything worth replacing the inherited one with.
    guard let path = environment["PATH"], !path.isEmpty else { return nil }
    return environment
  }
}
