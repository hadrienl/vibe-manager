import Foundation

/// What one `git` invocation answered.
public struct GitCommandResult: Hashable, Sendable {
  public let exitCode: Int32
  public let output: Data
  public let errorOutput: String

  public init(exitCode: Int32, output: Data = Data(), errorOutput: String = "") {
    self.exitCode = exitCode
    self.output = output
    self.errorOutput = errorOutput
  }

  public init(exitCode: Int32, text: String, errorOutput: String = "") {
    self.init(exitCode: exitCode, output: Data(text.utf8), errorOutput: errorOutput)
  }

  public var succeeded: Bool { exitCode == 0 }

  /// The standard output as text, with the final newline Git always prints removed.
  public var text: String {
    var text = String(decoding: output, as: UTF8.self)
    while text.hasSuffix("\n") { text.removeLast() }
    return text
  }
}

/// Why `git` itself could not be run — as opposed to a command it ran and refused.
public enum GitUnavailable: Error, Hashable, Sendable, LocalizedError {
  case notInstalled
  /// `/usr/bin/git` is the Xcode stub, and the developer tools it would forward to are absent.
  case commandLineToolsMissing
  case failedToStart(String)

  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "Git is not installed on this Mac."
    case .commandLineToolsMissing:
      return "Git needs the Command Line Tools, which are not installed."
    case .failedToStart(let reason):
      return "Git could not be started: \(reason)"
    }
  }
}

/// `git`, seen as a port.
///
/// The arguments are an array and never a command line: no path is ever turned back into shell
/// text on its way to Git, so a folder called `l'API (v2)` needs no quoting at all.
public protocol GitCommandRunner: Sendable {
  /// Runs `git` with `arguments`, from `directory`.
  ///
  /// A command Git ran and refused is a result with a non-zero status; only a Git that could not
  /// be run at all throws, and it throws `GitUnavailable`.
  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult
}

/// A path compared the way the file system does: through its symbolic links.
///
/// Worktrees, temporary folders and a folder designated through a link all reach the same place by
/// different spellings — `/var` and `/private/var` on every Mac — and comparing the spellings would
/// file a repository under the wrong folder.
public enum CanonicalPath {
  public static func of(_ path: String) -> String {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    var remainder: [String] = []
    // A path that no longer exists is resolved through its deepest ancestor that does: that is
    // where a link would be.
    while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
      remainder.insert(url.lastPathComponent, at: 0)
      url.deleteLastPathComponent()
    }
    var resolved = url.resolvingSymlinksInPath()
    for component in remainder {
      resolved.appendPathComponent(component)
    }
    return resolved.path
  }
}
