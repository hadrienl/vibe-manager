import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

/// A scratch folder for one test, removed by the test itself — never by the code under test.
struct Sandbox {
  let root: String

  init() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeGitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    root = CanonicalPath.of(url.path)
  }

  func path(_ components: String...) -> String {
    components.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
  }

  var worktreeRoot: String { path("Worktrees") }

  func remove() {
    try? FileManager.default.removeItem(atPath: root)
  }
}

/// Runs git for the fixtures and the assertions, and fails the test when git refuses.
@discardableResult
func git(_ arguments: [String], in directory: String) async throws -> String {
  let result = try await ProcessGitCommandRunner().run(arguments, in: directory)
  guard result.succeeded else {
    Issue.record("git \(arguments.joined(separator: " ")) failed: \(result.errorOutput)")
    throw FixtureError.gitFailed(result.errorOutput)
  }
  return result.text
}

enum FixtureError: Error {
  case gitFailed(String)
}

/// A repository with one commit on `main`.
func makeRepository(at path: String) async throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try await git(["init", "-q", "-b", "main"], in: path)
  try await git(["config", "user.name", "Vibe Tests"], in: path)
  try await git(["config", "user.email", "tests@example.com"], in: path)
  try await git(["config", "commit.gpgsign", "false"], in: path)
  try Data("hello\n".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("README"))
  try await git(["add", "README"], in: path)
  try await git(["commit", "-q", "-m", "Initial commit"], in: path)
}

func fileExists(_ path: String) -> Bool {
  FileManager.default.fileExists(atPath: path)
}

/// Delegates to the real git and keeps every argument list it was asked to run.
actor RecordingGitRunner: GitCommandRunner {
  private let real = ProcessGitCommandRunner()
  private(set) var commands: [[String]] = []

  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    commands.append(arguments)
    return try await real.run(arguments, in: directory)
  }

  func ran(_ fragment: [String]) -> Bool {
    commands.contains { command in
      guard command.count >= fragment.count else { return false }
      return (0...(command.count - fragment.count)).contains {
        Array(command[$0..<($0 + fragment.count)]) == fragment
      }
    }
  }
}

/// Delegates to the real git, and fails the test the moment anything destructive is asked of it.
struct GuardedGitRunner: GitCommandRunner {
  private let real = ProcessGitCommandRunner()

  static let forbidden: [[String]] = [
    ["worktree", "remove"], ["worktree", "prune"], ["branch", "-d"], ["branch", "-D"], ["rm"],
  ]

  func run(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    for fragment in Self.forbidden where Self.contains(arguments, fragment) {
      Issue.record("A destructive git command was run: git \(arguments.joined(separator: " "))")
    }
    return try await real.run(arguments, in: directory)
  }

  private static func contains(_ arguments: [String], _ fragment: [String]) -> Bool {
    guard arguments.count >= fragment.count else { return false }
    return (0...(arguments.count - fragment.count)).contains {
      Array(arguments[$0..<($0 + fragment.count)]) == fragment
    }
  }
}

/// The services the application wires, over the given runner and a temporary worktree root.
func services(
  runner: any GitCommandRunner,
  root: String,
  serializer: GitWriteSerializer = GitWriteSerializer()
) -> SessionWorkspaceServices {
  SessionWorkspaceServices(
    inspector: GitRepositoryInspector(git: runner),
    writer: GitWorktreeService(git: runner, serializer: serializer),
    root: FixedWorktreeRoot(path: root)
  )
}

func slug(_ raw: String) -> SessionSlug {
  guard let slug = SessionSlug(raw) else { preconditionFailure("Invalid test slug \(raw)") }
  return slug
}
