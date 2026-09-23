import Foundation
import VibeApplication

/// Runs the system's `git`, with an array of arguments and never through a shell.
///
/// Every command it is asked for is plumbing — `rev-parse`, `reflog`, `status --porcelain -z` —
/// whose output is stable across versions and parses without heuristics. The environment is an
/// allowlist, Git is told never to prompt, and reads take no optional lock, so inspecting a
/// repository an agent is committing in never collides with it.
public struct ProcessGitCommandRunner: GitCommandRunner {
  private let executable: GitExecutable
  private let timeout: Duration

  public init(
    candidates: [String] = ProcessGitCommandRunner.defaultCandidates,
    timeout: Duration = .seconds(120)
  ) {
    executable = GitExecutable(candidates: candidates)
    self.timeout = timeout
  }

  public static let defaultCandidates = [
    "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
  ]

  public func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    let path = try await executable.resolve()
    let timeoutSeconds = Double(timeout.components.seconds)
    let environment = Self.environment()
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(
            returning: try Self.execute(
              path: path,
              arguments: arguments,
              directory: directory,
              environment: environment,
              timeoutSeconds: timeoutSeconds
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
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

  private static func execute(
    path: String,
    arguments: [String],
    directory: String,
    environment: [String: String],
    timeoutSeconds: Double
  ) throws -> GitCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    process.standardInput = FileHandle.nullDevice

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      throw GitUnavailable.failedToStart(error.localizedDescription)
    }

    let buffers = PipeBuffers()
    let readers = DispatchGroup()
    buffers.drain(output.fileHandleForReading, into: .output, group: readers)
    buffers.drain(error.fileHandleForReading, into: .error, group: readers)

    if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
      process.terminate()
      _ = exited.wait(timeout: .now() + 2)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      readers.wait()
      return GitCommandResult(
        exitCode: -1,
        output: buffers.output,
        errorOutput: "git did not answer within \(Int(timeoutSeconds)) seconds."
      )
    }
    readers.wait()
    return GitCommandResult(
      exitCode: process.terminationStatus,
      output: buffers.output,
      errorOutput: String(decoding: buffers.error, as: UTF8.self)
    )
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
  func resolve() throws -> String {
    if let resolved { return resolved }
    let path = try Self.locate(candidates).get()
    resolved = path
    return path
  }

  private static func locate(_ candidates: [String]) -> Result<String, GitUnavailable> {
    let manager = FileManager.default
    var sawStub = false
    for candidate in candidates where manager.isExecutableFile(atPath: candidate) {
      if candidate == "/usr/bin/git", !developerToolsInstalled() {
        sawStub = true
        continue
      }
      return .success(candidate)
    }
    return .failure(sawStub ? .commandLineToolsMissing : .notInstalled)
  }

  private static func developerToolsInstalled() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }
}

/// Both pipes are drained at once: a command that fills one of them would otherwise wait forever
/// for a reader that is blocked on the other.
private final class PipeBuffers: @unchecked Sendable {
  enum Stream: Hashable {
    case output
    case error
  }

  private let lock = NSLock()
  private var storage: [Stream: Data] = [:]

  var output: Data { lock.withLock { storage[.output] ?? Data() } }
  var error: Data { lock.withLock { storage[.error] ?? Data() } }

  func drain(_ handle: FileHandle, into stream: Stream, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      let data = (try? handle.readToEnd()) ?? Data()
      self.lock.withLock { self.storage[stream] = data }
    }
  }
}
