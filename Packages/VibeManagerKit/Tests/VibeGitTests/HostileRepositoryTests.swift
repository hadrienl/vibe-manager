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

  /// A repository whose `a.txt` goes through the filter driver `driver`, committed before the
  /// driver is defined, and a payload that leaves `marker` behind if Git ever runs it.
  private func makeFilteredRepository(
    at repository: String, driver: String = "evil", in sandbox: Sandbox
  ) async throws -> (payload: String, marker: String) {
    try await makeRepository(at: repository)
    try Data("*.txt filter=\(driver)\n".utf8)
      .write(to: URL(fileURLWithPath: repository).appendingPathComponent(".gitattributes"))
    try Data("hello\n".utf8)
      .write(to: URL(fileURLWithPath: repository).appendingPathComponent("a.txt"))
    try await git(["add", ".gitattributes", "a.txt"], in: repository)
    try await git(["commit", "-q", "-m", "Filtered file"], in: repository)
    let marker = sandbox.path("ran-\(UUID().uuidString)")
    let payload = sandbox.path("payload-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8)
      .write(to: URL(fileURLWithPath: payload))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload)
    return (payload, marker)
  }

  /// Same size, another date: Git has to hash the file again, through its filter.
  private func touchFiltered(in repository: String) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3600)],
      ofItemAtPath: (repository as NSString).appendingPathComponent("a.txt"))
  }

  /// Every reading the application makes of the working tree.
  private func readEverything(_ repository: String) async throws {
    try touchFiltered(in: repository)
    _ = try await ProcessGitCommandRunner().run(
      ["--no-optional-locks", "status", "--porcelain=v2", "-z"], in: repository)
    try touchFiltered(in: repository)
    _ = await GitStatusReader().status(atPath: repository, limit: 100)
    try touchFiltered(in: repository)
    _ = await GitStatusReader().untrackedFiles(in: ".", atPath: repository, limit: 100)
    try touchFiltered(in: repository)
    _ = await GitActivityReader().hasUncommittedChanges(atPath: repository, since: .distantPast)
  }

  @Test("A clean or process filter from its own configuration never runs")
  func ownFilters() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    for variable in ["clean", "process", "smudge"] {
      let repository = sandbox.path("filtered-\(variable)")
      let (payload, marker) = try await makeFilteredRepository(at: repository, in: sandbox)
      try await git(["config", "filter.evil.\(variable)", payload], in: repository)
      try await readEverything(repository)
      #expect(!FileManager.default.fileExists(atPath: marker), "filter.evil.\(variable) ran")
    }
  }

  @Test("A filter the repository marks as required is switched off all the same, and read")
  func requiredFilter() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("required")
    let (payload, marker) = try await makeFilteredRepository(at: repository, in: sandbox)
    try await git(["config", "filter.evil.clean", payload], in: repository)
    try await git(["config", "filter.evil.required", "true"], in: repository)
    try touchFiltered(in: repository)

    let status = await GitStatusReader().status(atPath: repository, limit: 100)

    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect((try? status.get()) != nil)
  }

  @Test("A filter it includes, plainly or on a condition, never runs")
  func includedFilters() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    // `**/`: Git matches the real path of the repository, `/private/var/…` for a `/var/…` sandbox.
    let folder = (sandbox.root as NSString).lastPathComponent
    for key in ["include.path", "includeIf.gitdir:**/\(folder)/.path"] {
      let repository = sandbox.path("included-\(UUID().uuidString)")
      let (payload, marker) = try await makeFilteredRepository(at: repository, in: sandbox)
      let included = sandbox.path("included-\(UUID().uuidString).cfg")
      try Data("[filter \"evil\"]\n\tclean = \(payload)\n".utf8)
        .write(to: URL(fileURLWithPath: included))
      try await git(["config", key, included], in: repository)
      // The control: Git does see the included driver, so only the guard keeps it from running.
      let seen = try await git(
        ["config", "--includes", "--get", "filter.evil.clean"], in: repository)
      #expect(seen == payload, "\(key) did not include its file")
      try await readEverything(repository)
      #expect(!FileManager.default.fileExists(atPath: marker), "\(key) ran its filter")
    }
  }

  @Test("A driver whose name holds a dot or an equals sign never runs")
  func oddNames() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    for driver in ["Ev.il", "we=ird"] {
      let repository = sandbox.path("odd-\(UUID().uuidString)")
      let (payload, marker) = try await makeFilteredRepository(
        at: repository, driver: driver, in: sandbox)
      let configuration = (repository as NSString).appendingPathComponent(".git/config")
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: configuration))
      handle.seekToEndOfFile()
      handle.write(Data("[filter \"\(driver)\"]\n\tclean = \(payload)\n".utf8))
      try handle.close()
      try await readEverything(repository)
      #expect(!FileManager.default.fileExists(atPath: marker), "\(driver) ran")
    }
  }

  @Test("A filter a submodule defines never runs, whatever the submodule asks to be ignored")
  func submoduleFilter() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let inner = sandbox.path("inner")
    let (payload, marker) = try await makeFilteredRepository(at: inner, in: sandbox)
    let repository = sandbox.path("outer")
    try await makeRepository(at: repository)
    try await git(
      ["-c", "protocol.file.allow=always", "submodule", "add", "-q", inner, "inner"],
      in: repository)
    try await git(["commit", "-q", "-m", "Submodule"], in: repository)
    let checkout = (repository as NSString).appendingPathComponent("inner")
    try await git(["config", "filter.evil.clean", payload], in: checkout)
    try await git(["config", "submodule.inner.ignore", "none"], in: repository)

    for _ in 0..<2 {
      try touchFiltered(in: checkout)
      _ = await GitStatusReader().status(atPath: repository, limit: 100)
      try touchFiltered(in: checkout)
      _ = await GitActivityReader().hasUncommittedChanges(atPath: repository, since: .distantPast)
    }

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
