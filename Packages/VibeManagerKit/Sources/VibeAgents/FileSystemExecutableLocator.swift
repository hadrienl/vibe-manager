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

  public init(
    fileSystem: any ExecutableFileSystem = DefaultExecutableFileSystem(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    probe: (any ProcessProbe)? = nil,
    loginShellTimeout: Duration = .seconds(3)
  ) {
    self.fileSystem = fileSystem
    self.environment = environment
    self.probe = probe
    self.loginShellTimeout = loginShellTimeout
  }

  public func locate(_ plan: ExecutableSearchPlan) async -> ExecutableLocation {
    if let userDefinedPath = plan.userDefinedPath, !userDefinedPath.isEmpty {
      return inspect(path: userDefinedPath, source: .userDefined)
    }

    for directory in plan.candidateDirectories {
      let path = expand(directory) + "/" + plan.binaryName
      guard fileSystem.fileExists(atPath: path) else { continue }
      return inspect(path: path, source: .candidateDirectory)
    }

    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let path = expand(String(directory)) + "/" + plan.binaryName
      guard fileSystem.fileExists(atPath: path) else { continue }
      return inspect(path: path, source: .processPath)
    }

    guard plan.allowsLoginShellFallback, let path = await loginShellPath(for: plan.binaryName)
    else {
      return .notFound
    }
    return inspect(path: path, source: .loginShell)
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
  private func loginShellPath(for binaryName: String) async -> String? {
    guard let probe else { return nil }

    let shell = environment["SHELL"] ?? "/bin/zsh"
    guard fileSystem.isExecutableFile(atPath: shell) else { return nil }

    let result = try? await probe.run(
      executablePath: shell,
      arguments: ["-l", "-c", "command -v -- \(shellQuoted(binaryName))"],
      environment: AgentEnvironmentPolicy.environment(base: environment),
      workingDirectoryPath: nil,
      timeout: loginShellTimeout
    )
    guard let result, result.exitCode == 0, !result.didTimeOut else { return nil }

    let path =
      result.standardOutput
      .split(separator: "\n")
      .last
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard path.hasPrefix("/") else { return nil }
    return path
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
