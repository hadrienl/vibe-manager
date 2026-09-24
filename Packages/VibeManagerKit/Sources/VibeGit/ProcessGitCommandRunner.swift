import Foundation
import VibeApplication
import VibeProcess

/// Runs the system's `git`, with an array of arguments and never through a shell.
///
/// Every command it is asked for is plumbing — `rev-parse`, `reflog`, `status --porcelain -z` —
/// whose output is stable across versions and parses without heuristics. The environment is an
/// allowlist, Git is told never to prompt, and reads take no optional lock, so inspecting a
/// repository an agent is committing in never collides with it.
///
/// A repository is only ever read, and it may be one the user merely opened: its local
/// configuration is not trusted to run anything. `hardeningOptions` switch off the two settings
/// through which a plain `git status` executes a command of the repository's choosing.
public struct ProcessGitCommandRunner: GitCommandRunner {
  private let executable: GitExecutable
  private let timeout: Duration
  private let diagnostics: any DiagnosticLog

  public init(
    candidates: [String] = ProcessGitCommandRunner.defaultCandidates,
    timeout: Duration = .seconds(120),
    diagnostics: any DiagnosticLog = NullDiagnosticLog()
  ) {
    executable = GitExecutable(candidates: candidates)
    self.timeout = timeout
    self.diagnostics = diagnostics
  }

  public static let defaultCandidates = [
    "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
  ]

  /// Passed before every command. `core.fsmonitor` names a program Git runs to learn what changed,
  /// and `core.hooksPath` a folder of programs it runs around some commands: both are read from a
  /// repository's own `.git/config`, which is how a hostile repository runs code in whoever
  /// inspects it. The user's global configuration is still read for everything else.
  public static let hardeningOptions = [
    "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
  ]

  /// Output kept from one command. A `status` of a repository of a hundred thousand files fits
  /// many times over; a command that writes more is reported as failed rather than cut, since a
  /// truncated `-z` listing would parse into a wrong one.
  static let outputByteLimit = 64 << 20

  public func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    let path = try await executable.resolve()
    let startedAt = ContinuousClock.now
    let result: BoundedProcessResult
    do {
      result = try await BoundedProcess.run(
        BoundedProcessRequest(
          executablePath: path,
          arguments: Self.hardeningOptions + arguments,
          environment: Self.environment(),
          workingDirectoryPath: directory,
          timeout: timeout,
          outputByteLimit: Self.outputByteLimit
        )
      )
    } catch BoundedProcessError.launchFailed(let code) {
      diagnostics.record(
        .git, .error, "git.launchFailed",
        ["verb": .token(Self.verb(of: arguments)), "errno": .code(code)])
      throw GitUnavailable.failedToStart(String(cString: strerror(code)))
    }
    note(result, arguments: arguments, directory: directory, duration: .now - startedAt)

    if result.didTimeOut {
      return GitCommandResult(
        exitCode: -1,
        output: result.standardOutput,
        errorOutput: "git did not answer within \(Int(timeout.components.seconds)) seconds."
      )
    }
    if result.outputTruncated {
      return GitCommandResult(exitCode: -1, errorOutput: "git wrote more than can be read.")
    }
    return GitCommandResult(
      exitCode: result.exitCode,
      output: result.standardOutput,
      errorOutput: String(decoding: result.standardError, as: UTF8.self)
    )
  }

  /// The verb alone: every other argument may be a path, a branch name or a revision.
  static func verb(of arguments: [String]) -> DiagnosticToken {
    switch arguments.first {
    case "status": return DiagnosticToken("status")
    case "rev-parse": return DiagnosticToken("rev-parse")
    case "symbolic-ref": return DiagnosticToken("symbolic-ref")
    case "reflog": return DiagnosticToken("reflog")
    case "for-each-ref": return DiagnosticToken("for-each-ref")
    case "merge-base": return DiagnosticToken("merge-base")
    case "rev-list": return DiagnosticToken("rev-list")
    case "diff": return DiagnosticToken("diff")
    case "--no-optional-locks": return verb(of: Array(arguments.dropFirst()))
    default: return DiagnosticToken("other")
    }
  }

  /// Every command at `debug`: `git status` runs whenever a repository moves. A command that
  /// timed out or wrote too much is an error, with the repository it was run in, redacted.
  private func note(
    _ result: BoundedProcessResult, arguments: [String], directory: String, duration: Duration
  ) {
    let failed = result.didTimeOut || result.outputTruncated
    diagnostics.record(
      .git, failed ? .error : .debug, failed ? "git.commandFailed" : "git.command",
      [
        "verb": .token(Self.verb(of: arguments)),
        "code": .code(result.exitCode),
        "timedOut": .flag(result.didTimeOut),
        "truncated": .flag(result.outputTruncated),
        "duration": .duration(duration),
        "repository": .path(RedactedPath(directory)),
      ])
  }

  static func environment(
    inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let kept: Set<String> = ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]
    var environment = inherited.filter { kept.contains($0.key) }
    if environment["PATH"]?.isEmpty ?? true {
      environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    // English, whatever the user's region: Git's sentences are shown as they are, and the rest of
    // the interface is in English.
    environment["LANG"] = "en_US.UTF-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    return environment
  }
}

/// Finds a `git` that actually works, once.
///
/// On a Mac without the Command Line Tools, `/usr/bin/git` exists and is a stub whose only job is
/// to offer installing them — in a dialog, on top of whatever the user was doing. It is recognised
/// by asking `xcode-select` where the developer tools are, before it is ever run.
actor GitExecutable {
  private let candidates: [String]
  private var resolved: String?

  init(candidates: [String]) {
    self.candidates = candidates
  }

  /// Only a success is kept. A Git found missing is looked for again next time: the remedy is to
  /// install it, and "try again" must then work without relaunching the application.
  func resolve() async throws -> String {
    if let resolved { return resolved }
    let path = try await Self.locate(candidates).get()
    resolved = path
    return path
  }

  private static func locate(_ candidates: [String]) async -> Result<String, GitUnavailable> {
    let manager = FileManager.default
    var sawStub = false
    for candidate in candidates where manager.isExecutableFile(atPath: candidate) {
      if candidate == "/usr/bin/git", await !developerToolsInstalled() {
        sawStub = true
        continue
      }
      return .success(candidate)
    }
    return .failure(sawStub ? .commandLineToolsMissing : .notInstalled)
  }

  /// `xcode-select -p` answers at once, from a file; five seconds is for a Mac under load. One
  /// that does not answer counts as no tools, and is asked again on the next look.
  private static func developerToolsInstalled() async -> Bool {
    let result = try? await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/xcode-select",
        arguments: ["-p"],
        environment: ProcessGitCommandRunner.environment(),
        timeout: .seconds(5),
        outputByteLimit: 4096
      )
    )
    return result?.termination == .exited(0)
  }
}
