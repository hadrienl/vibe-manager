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

  /// What Git said went wrong, on one line, for a sentence in front of the user.
  public var errorSummary: String {
    let lines = errorOutput.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    return lines.first { !$0.isEmpty }.map { line in
      line.hasPrefix("fatal: ") ? String(line.dropFirst(7)) : line
    } ?? "git exited with status \(exitCode)."
  }
}

/// Why `git` itself could not be run — as opposed to a command it ran and refused.
///
/// Shaped like the diagnostic of an unavailable agent, a sentence and a remedy: on a new Mac,
/// `/usr/bin/git` exists and does nothing but ask for the Command Line Tools, and saying that is
/// worth more than an exit status of 1 with no sentence.
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

  public var recoverySuggestion: String? {
    switch self {
    case .notInstalled, .commandLineToolsMissing:
      return "Install them with xcode-select --install, then try again."
    case .failedToStart:
      return "Check that git runs in a terminal, then try again."
    }
  }

  public var command: String? {
    switch self {
    case .notInstalled, .commandLineToolsMissing: return "xcode-select --install"
    case .failedToStart: return nil
    }
  }
}

/// `git`, seen as a port.
///
/// The arguments are an array and never a command line: no path is ever turned back into shell
/// text on its way to Git, so a folder called `l'API (v2)` needs no quoting at all. It is also what
/// makes every plan testable without a repository, while the integration tests still create real
/// ones behind the process implementation.
public protocol GitCommandRunner: Sendable {
  /// Runs `git` with `arguments`, from `directory`.
  ///
  /// A command Git ran and refused is a result with a non-zero status; only a Git that could not
  /// be run at all throws, and it throws `GitUnavailable`.
  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult
}

/// Turns a path back into text for the one place it has to be: a command the user copies into a
/// shell. Single quotes, with the single quotes of the path itself closed and escaped.
public enum ShellQuoting {
  public static func quote(_ argument: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) && $0.isASCII }) {
      return argument
    }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func command(_ arguments: [String]) -> String {
    arguments.map(quote).joined(separator: " ")
  }
}

/// A path compared the way the file system does: through its symbolic links.
///
/// Worktrees, temporary folders and a repository designated through a link all reach the same
/// place by different spellings — `/var` and `/private/var` on every Mac — and comparing the
/// spellings would attach one repository twice, or plan a worktree on top of itself.
public enum CanonicalPath {
  public static func of(_ path: String) -> String {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    var remainder: [String] = []
    // A path that does not exist yet is resolved through its deepest ancestor that does: that is
    // where a link would be, and what `git worktree add` will write under.
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
