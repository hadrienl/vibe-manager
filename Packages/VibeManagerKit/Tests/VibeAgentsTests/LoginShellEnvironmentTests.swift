import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Login shell environment")
struct LoginShellEnvironmentTests {
  private static func output(_ entries: [String], noise: String = "") -> String {
    noise + LoginShellEnvironment.marker + entries.joined(separator: "\0")
  }

  @Test("Only the adopted variables are read, whatever the configuration printed before")
  func readsAdoptedKeysAfterTheMarker() {
    let parsed = LoginShellEnvironment.parse(
      Self.output(
        [
          "PATH=/Users/test/.local/bin:/usr/bin", "NVM_DIR=/Users/test/.nvm",
          "AWS_SECRET_ACCESS_KEY=secret", "CLAUDE_CONFIG_DIR=/elsewhere",
        ],
        noise: "Welcome back!\nPATH=/wrong\0"
      ))

    #expect(parsed == ["PATH": "/Users/test/.local/bin:/usr/bin", "NVM_DIR": "/Users/test/.nvm"])
  }

  @Test("A value containing an equals sign is kept whole")
  func keepsEqualsSignsInValues() {
    let parsed = LoginShellEnvironment.parse(Self.output(["PATH=/a=b:/usr/bin"]))

    #expect(parsed?["PATH"] == "/a=b:/usr/bin")
  }

  @Test("Without the marker or a PATH, the shell has said nothing")
  func refusesIncompleteOutput() {
    #expect(LoginShellEnvironment.parse("PATH=/usr/bin") == nil)
    #expect(LoginShellEnvironment.parse(Self.output(["NVM_DIR=/Users/test/.nvm"])) == nil)
    #expect(LoginShellEnvironment.parse(Self.output(["PATH="])) == nil)
  }

  @Test("The user's shell is asked as a login and interactive shell")
  func asksTheUsersShell() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(
        ProbeResult(exitCode: 0, standardOutput: Self.output(["PATH=/opt/homebrew/bin"]))))
    let shell = LoginShellEnvironment(
      inherited: ["SHELL": "/bin/bash", "PATH": "/usr/bin"], probe: probe)

    let environment = await shell.environment()

    #expect(environment == ["PATH": "/opt/homebrew/bin"])
    #expect(probe.invocations.map(\.executablePath) == ["/bin/bash"])
    #expect(probe.invocations.first?.arguments.prefix(3) == ["-l", "-i", "-c"])
  }

  @Test("An answer is kept: the shell is asked once")
  func cachesAnAnswer() async {
    let probe = StubProcessProbe(
      defaultResponse: .success(
        ProbeResult(exitCode: 0, standardOutput: Self.output(["PATH=/opt/homebrew/bin"]))))
    let shell = LoginShellEnvironment(inherited: [:], probe: probe)

    _ = await shell.environment()
    _ = await shell.environment()

    #expect(probe.invocations.count == 1)
  }

  @Test("A shell that did not answer is asked again next time")
  func retriesAfterSilence() async {
    let probe = ScriptedProcessProbe(responses: [
      .success(ProbeResult(exitCode: -1, didTimeOut: true)),
      .success(ProbeResult(exitCode: 0, standardOutput: Self.output(["PATH=/opt/homebrew/bin"]))),
    ])
    let shell = LoginShellEnvironment(inherited: [:], probe: probe)

    #expect(await shell.environment() == nil)
    #expect(await shell.environment() == ["PATH": "/opt/homebrew/bin"])
    #expect(probe.invocations.count == 2)
  }

  @Test("A failing shell or one that cannot start gives nothing")
  func failuresGiveNothing() async {
    let failing = LoginShellEnvironment(
      inherited: [:],
      probe: StubProcessProbe(
        defaultResponse: .success(
          ProbeResult(exitCode: 1, standardOutput: Self.output(["PATH=/opt/homebrew/bin"])))))
    let missing = LoginShellEnvironment(
      inherited: [:], probe: StubProcessProbe(defaultResponse: .failure(.launchFailed)))

    #expect(await failing.environment() == nil)
    #expect(await missing.environment() == nil)
  }

  @Test("The real shell of this machine answers with a PATH", .timeLimit(.minutes(1)))
  func realShellAnswers() async {
    let shell = LoginShellEnvironment(
      inherited: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
      probe: SystemProcessProbe())

    let path = await shell.environment()?["PATH"]

    #expect(path?.contains("/usr/bin") == true)
  }
}
