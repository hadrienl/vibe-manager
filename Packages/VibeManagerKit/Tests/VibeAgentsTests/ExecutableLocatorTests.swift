import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Executable detection")
struct ExecutableLocatorTests {
  private let environment = [
    "PATH": "/usr/bin:/sbin",
    "HOME": "/Users/test",
    "SHELL": "/bin/zsh",
  ]

  @Test("A user defined path wins over every other source")
  func userDefinedPathWins() async {
    let fileSystem = StubFileSystem(
      executables: ["/custom/stub-agent", "/opt/homebrew/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(
        binaryName: "stub-agent",
        candidateDirectories: ["/opt/homebrew/bin"],
        userDefinedPath: "/custom/stub-agent"
      )
    )

    #expect(location == .found(path: "/custom/stub-agent", source: .userDefined))
  }

  @Test("Candidate directories are probed before the inherited PATH")
  func candidateDirectoriesBeforePath() async {
    let fileSystem = StubFileSystem(
      executables: ["/opt/homebrew/bin/stub-agent", "/usr/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["/opt/homebrew/bin"])
    )

    #expect(location == .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory))
  }

  @Test("A tilde prefixed candidate directory is expanded against HOME")
  func expandsTilde() async {
    let fileSystem = StubFileSystem(executables: ["/Users/test/.local/bin/stub-agent"])
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["~/.local/bin"])
    )

    #expect(
      location == .found(path: "/Users/test/.local/bin/stub-agent", source: .candidateDirectory)
    )
  }

  @Test("The inherited PATH is used when no candidate directory matches")
  func fallsBackToProcessPath() async {
    let fileSystem = StubFileSystem(executables: ["/usr/bin/stub-agent"])
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["/opt/homebrew/bin"])
    )

    #expect(location == .found(path: "/usr/bin/stub-agent", source: .processPath))
  }

  @Test("Symbolic links are resolved to the real executable")
  func resolvesSymlinks() async {
    let fileSystem = StubFileSystem(
      executables: ["/opt/homebrew/Cellar/stub/bin/stub-agent"],
      symlinks: ["/opt/homebrew/bin/stub-agent": "/opt/homebrew/Cellar/stub/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["/opt/homebrew/bin"])
    )

    #expect(
      location
        == .found(
          path: "/opt/homebrew/Cellar/stub/bin/stub-agent",
          source: .candidateDirectory
        )
    )
  }

  @Test("A file that exists without the executable bit is reported as such")
  func reportsNonExecutableFile() async {
    let fileSystem = StubFileSystem(nonExecutableFiles: ["/opt/homebrew/bin/stub-agent"])
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["/opt/homebrew/bin"])
    )

    #expect(
      location == .notExecutable(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
    )
  }

  @Test("The login shell is asked last and its answer is trusted only when absolute")
  func usesLoginShellFallback() async {
    let fileSystem = StubFileSystem(executables: ["/bin/zsh", "/Users/test/.bun/bin/stub-agent"])
    let probe = StubProcessProbe(
      responses: [
        "/bin/zsh": .success(
          ProbeResult(exitCode: 0, standardOutput: "/Users/test/.bun/bin/stub-agent")
        )
      ]
    )
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    let location = await locator.locate(ExecutableSearchPlan(binaryName: "stub-agent"))

    #expect(location == .found(path: "/Users/test/.bun/bin/stub-agent", source: .loginShell))
    #expect(probe.invocations.first?.arguments.first == "-l")
    // The binary itself must never be executed while looking for it.
    #expect(probe.invocations.allSatisfy { $0.executablePath == "/bin/zsh" })
  }

  @Test("A relative login shell answer is rejected")
  func rejectsRelativeLoginShellAnswer() async {
    let fileSystem = StubFileSystem(executables: ["/bin/zsh"])
    let probe = StubProcessProbe(
      responses: ["/bin/zsh": .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent"))]
    )
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    #expect(await locator.locate(ExecutableSearchPlan(binaryName: "stub-agent")) == .notFound)
  }

  @Test("Nothing anywhere yields notFound rather than an error")
  func missingEverywhere() async {
    let locator = FileSystemExecutableLocator(
      fileSystem: StubFileSystem(),
      environment: environment
    )

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", allowsLoginShellFallback: false)
    )

    #expect(location == .notFound)
  }
}
