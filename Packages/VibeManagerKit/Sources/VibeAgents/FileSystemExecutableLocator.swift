import Foundation
import VibeApplication

/// Inspects the file system, the inherited `PATH` and, as a last resort, a login shell.
///
/// An application launched from the Finder inherits the `PATH` of `launchd`, not the one the
/// user sees in their terminal, so relying on `PATH` alone hides most Homebrew and version
/// manager installations.
public struct FileSystemExecutableLocator: ExecutableLocator {
  private let fileSystem: any ExecutableFileSystem
  private let environment: [String: String]
  private let probe: (any ProcessProbe)?
  private let loginShellTimeout: Duration
  private let loginShellRetryTimeout: Duration

  public init(
    fileSystem: any ExecutableFileSystem = DefaultExecutableFileSystem(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    probe: (any ProcessProbe)? = nil,
    loginShellTimeout: Duration = .seconds(3),
    loginShellRetryTimeout: Duration = .seconds(10)
  ) {
    self.fileSystem = fileSystem
    self.environment = environment
    self.probe = probe
    self.loginShellTimeout = loginShellTimeout
    // A retry budget narrower than the first attempt would make the second one strictly less
    // likely to answer, which is the opposite of the point.
    self.loginShellRetryTimeout = max(loginShellRetryTimeout, loginShellTimeout)
  }

  public func locate(_ plan: ExecutableSearchPlan) async -> ExecutableLocation {
    if let userDefinedPath = plan.userDefinedPath, !userDefinedPath.isEmpty {
      return inspect(path: userDefinedPath, source: .userDefined)
    }

    // A file that exists but cannot be run must not shadow a working installation further down
    // the search order: a leftover from a failed install would otherwise mask the real binary.
    // It is only reported when nothing else matches.
    var shadowed: ExecutableLocation?

    func consider(path: String, source: AgentDetectionSource) -> ExecutableLocation? {
      let location = inspect(path: path, source: source)
      switch location {
      case .found:
        return location
      case .notExecutable:
        shadowed = shadowed ?? location
        return nil
      case .notFound, .timedOut:
        return nil
      }
    }

    for directory in plan.candidateDirectories {
      let path = expand(directory) + "/" + plan.binaryName
      guard fileSystem.fileExists(atPath: path) else { continue }
      if let location = consider(path: path, source: .candidateDirectory) { return location }
    }

    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let path = expand(String(directory)) + "/" + plan.binaryName
      guard fileSystem.fileExists(atPath: path) else { continue }
      if let location = consider(path: path, source: .processPath) { return location }
    }

    guard plan.allowsLoginShellFallback else { return shadowed ?? .notFound }

    switch await loginShellPath(for: plan.binaryName) {
    case .path(let path):
      return consider(path: path, source: .loginShell) ?? shadowed ?? .notFound
    case .noAnswer:
      // A file found earlier, even a non executable one, says more than a silent shell.
      return shadowed ?? .timedOut
    case .unavailable:
      return shadowed ?? .notFound
    }
  }

  private func inspect(path: String, source: AgentDetectionSource) -> ExecutableLocation {
    let resolved = fileSystem.resolvedPath(for: path)
    guard fileSystem.fileExists(atPath: resolved) else { return .notFound }
    guard fileSystem.isExecutableFile(atPath: resolved) else {
      return .notExecutable(path: resolved, source: source)
    }
    return .found(path: resolved, source: source)
  }

  /// Asks the user's login shell where the binary lives, without running the binary itself.
  /// What asking the login shell produced.
  ///
  /// `noAnswer` is kept apart from `unavailable`: a shell that exits non zero has looked and not
  /// found the binary, while a shell that never answers has not looked yet.
  private enum LoginShellOutcome {
    case path(String)
    case noAnswer
    case unavailable
  }

  private func loginShellPath(for binaryName: String) async -> LoginShellOutcome {
    guard probe != nil else { return .unavailable }

    let shell = environment["SHELL"] ?? "/bin/zsh"
    guard fileSystem.isExecutableFile(atPath: shell) else { return .unavailable }

    var result = await ask(shell: shell, for: binaryName, timeout: loginShellTimeout)
    if result?.didTimeOut == true {
      // Same reasoning as the version probe: a login shell still sourcing a heavy configuration
      // has said nothing about the installation. The second attempt runs on a wider budget, and
      // on a shell whose start up the first one has just warmed up.
      result = await ask(shell: shell, for: binaryName, timeout: loginShellRetryTimeout)
    }

    guard let result else { return .unavailable }
    guard !result.didTimeOut else { return .noAnswer }
    guard result.exitCode == 0 else { return .unavailable }

    let path =
      result.standardOutput
      .split(separator: "\n")
      .last
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard path.hasPrefix("/") else { return .unavailable }
    return .path(path)
  }

  private func ask(shell: String, for binaryName: String, timeout: Duration) async -> ProbeResult? {
    try? await probe?.run(
      executablePath: shell,
      arguments: ["-l", "-c", "command -v -- \(shellQuoted(binaryName))"],
      environment: AgentEnvironmentPolicy.environment(base: environment),
      workingDirectoryPath: nil,
      timeout: timeout
    )
  }

  private func expand(_ directory: String) -> String {
    guard directory.hasPrefix("~") else { return directory }
    let home = environment["HOME"] ?? NSHomeDirectory()
    return home + directory.dropFirst()
  }

  private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public protocol ExecutableFileSystem: Sendable {
  func fileExists(atPath path: String) -> Bool
  func isExecutableFile(atPath path: String) -> Bool
  func resolvedPath(for path: String) -> String
}

public struct DefaultExecutableFileSystem: ExecutableFileSystem {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  public func isExecutableFile(atPath path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
  }

  public func resolvedPath(for path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
}
