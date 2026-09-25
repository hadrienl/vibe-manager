import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit

/// A repository the user only looks at must not run anything of its choosing.
@Suite("Reading a hostile repository")
struct HostileRepositoryTests {
  /// A repository whose own configuration names programs Git would run on a plain `status`.
  private func makeHostileRepository(in sandbox: Sandbox) async throws -> (String, String) {
    let repository = sandbox.path("hostile")
    try await makeRepository(at: repository)
    let marker = sandbox.path("ran")
    let script = sandbox.path("payload.sh")
    try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8)
      .write(to: URL(fileURLWithPath: script))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

    try await git(["config", "core.fsmonitor", script], in: repository)
    let hooks = sandbox.path("hooks")
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    for hook in ["post-index-change", "reference-transaction"] {
      let path = (hooks as NSString).appendingPathComponent(hook)
      try FileManager.default.copyItem(atPath: script, toPath: path)
    }
    try await git(["config", "core.hooksPath", hooks], in: repository)
    // A change, so that `status` has an index to refresh.
    try Data("changed\n".utf8)
      .write(to: URL(fileURLWithPath: repository).appendingPathComponent("README"))
    return (repository, marker)
  }

  @Test("Its fsmonitor and hooks are never run by the reads the inspector makes")
  func nothingRuns() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let (repository, marker) = try await makeHostileRepository(in: sandbox)

    let runner = ProcessGitCommandRunner()
    for arguments in [
      ["status", "--porcelain=v2", "-z", "--branch"],
      ["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
      ["rev-parse", "--show-toplevel"],
    ] {
      _ = try await runner.run(arguments, in: repository)
    }
    _ = await GitStatusReader().status(atPath: repository, limit: 100)

    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test("Every command is prefixed with the options that switch them off")
  func hardeningOptions() {
    #expect(
      ProcessGitCommandRunner.hardeningOptions == [
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
      ])
  }
}
