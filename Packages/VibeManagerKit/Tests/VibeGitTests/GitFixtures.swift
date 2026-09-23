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
