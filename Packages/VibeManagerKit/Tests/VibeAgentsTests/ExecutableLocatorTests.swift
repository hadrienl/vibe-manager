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

  @Test("A non executable candidate does not shadow a working installation")
  func nonExecutableCandidateDoesNotShadow() async {
    let fileSystem = StubFileSystem(
      executables: ["/usr/bin/stub-agent"],
      nonExecutableFiles: ["/opt/homebrew/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(
        binaryName: "stub-agent",
        candidateDirectories: ["/opt/homebrew/bin"],
        allowsLoginShellFallback: false
      )
    )

    #expect(location == .found(path: "/usr/bin/stub-agent", source: .processPath))
  }

  @Test("A non executable file is still reported when nothing else matches")
  func nonExecutableIsReportedAsALastResort() async {
    let fileSystem = StubFileSystem(nonExecutableFiles: ["/opt/homebrew/bin/stub-agent"])
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(
        binaryName: "stub-agent",
        candidateDirectories: ["/opt/homebrew/bin"],
        allowsLoginShellFallback: false
      )
    )

    #expect(
      location == .notExecutable(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
    )
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

  @Test("A login shell that stays silent is asked a second time on a wider budget")
  func retriesTheLoginShellOnce() async {
    let fileSystem = StubFileSystem(executables: ["/bin/zsh", "/Users/test/.bun/bin/stub-agent"])
    let probe = ScriptedProcessProbe(responses: [
      .success(ProbeResult(exitCode: -1, didTimeOut: true)),
      .success(ProbeResult(exitCode: 0, standardOutput: "/Users/test/.bun/bin/stub-agent")),
    ])
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    let location = await locator.locate(ExecutableSearchPlan(binaryName: "stub-agent"))

    // A shell still sourcing a heavy configuration is the common cold start, not a missing CLI.
    #expect(location == .found(path: "/Users/test/.bun/bin/stub-agent", source: .loginShell))
    #expect(probe.invocations.count == 2)
    #expect(probe.invocations.first?.timeout == .seconds(3))
    #expect(probe.invocations.last?.timeout == .seconds(10))
  }

  @Test("A login shell silent twice is inconclusive, not a missing agent")
  func aTwiceSilentLoginShellIsInconclusive() async {
    let fileSystem = StubFileSystem(executables: ["/bin/zsh"])
    let probe = StubProcessProbe(
      responses: ["/bin/zsh": .success(ProbeResult(exitCode: -1, didTimeOut: true))]
    )
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    let location = await locator.locate(ExecutableSearchPlan(binaryName: "stub-agent"))

    #expect(location == .timedOut)
    #expect(probe.invocations.count == 2)
  }

  @Test("A shell that looked and found nothing is still a missing agent")
  func aShellThatFoundNothingIsNotATimeout() async {
    let fileSystem = StubFileSystem(executables: ["/bin/zsh"])
    let probe = StubProcessProbe(
      responses: ["/bin/zsh": .success(ProbeResult(exitCode: 1))]
    )
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    #expect(await locator.locate(ExecutableSearchPlan(binaryName: "stub-agent")) == .notFound)
    // A non zero exit is an answer, so it is not retried.
    #expect(probe.invocations.count == 1)
  }

  @Test("A file found earlier outweighs a silent login shell")
  func aShadowedFileOutweighsASilentLoginShell() async {
    let fileSystem = StubFileSystem(
      executables: ["/bin/zsh"],
      nonExecutableFiles: ["/opt/homebrew/bin/stub-agent"]
    )
    let probe = StubProcessProbe(
      responses: ["/bin/zsh": .success(ProbeResult(exitCode: -1, didTimeOut: true))]
    )
    let locator = FileSystemExecutableLocator(
      fileSystem: fileSystem,
      environment: environment,
      probe: probe
    )

    let location = await locator.locate(
      ExecutableSearchPlan(binaryName: "stub-agent", candidateDirectories: ["/opt/homebrew/bin"])
    )

    #expect(
      location == .notExecutable(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
    )
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
  @Test("A native build further down the search order wins over one that needs Rosetta")
  func nativeBuildWinsOverTranslatedOne() async {
    // The Mac this was found on: an Intel Homebrew under /usr/local, and the native standalone
    // install under ~/.local/bin. The first costs half a minute of translation after each update.
    let fileSystem = StubFileSystem(
      executables: ["/usr/local/bin/stub-agent", "/Users/test/.local/bin/stub-agent"],
      translatedExecutables: ["/usr/local/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(
        binaryName: "stub-agent",
        candidateDirectories: ["/usr/local/bin", "~/.local/bin"],
        allowsLoginShellFallback: false
      )
    )

    #expect(
      location == .found(path: "/Users/test/.local/bin/stub-agent", source: .candidateDirectory)
    )
  }

  @Test("A build that needs Rosetta is still used when it is the only one")
  func translatedBuildIsALastResort() async {
    let fileSystem = StubFileSystem(
      executables: ["/usr/local/bin/stub-agent"],
      nonExecutableFiles: ["/Users/test/.local/bin/stub-agent"],
      translatedExecutables: ["/usr/local/bin/stub-agent"]
    )
    let locator = FileSystemExecutableLocator(fileSystem: fileSystem, environment: environment)

    let location = await locator.locate(
      ExecutableSearchPlan(
        binaryName: "stub-agent",
        candidateDirectories: ["/usr/local/bin", "~/.local/bin"],
        allowsLoginShellFallback: false
      )
    )

    // A binary that runs, however slowly, says more than a file that cannot run at all.
    #expect(location == .found(path: "/usr/local/bin/stub-agent", source: .candidateDirectory))
  }

  @Test("A path the user chose is kept even when it needs Rosetta")
  func userDefinedPathIsNeverSecondGuessed() async {
    let fileSystem = StubFileSystem(
      executables: ["/custom/stub-agent", "/opt/homebrew/bin/stub-agent"],
      translatedExecutables: ["/custom/stub-agent"]
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
}

@Suite("Mach-O architectures")
struct MachOArchitecturesTests {
  private func thin(cpuType: UInt32) -> Data {
    var data = Data([0xCF, 0xFA, 0xED, 0xFE])
    withUnsafeBytes(of: cpuType.littleEndian) { data.append(contentsOf: $0) }
    return data + Data(count: 24)
  }

  private func fat(cpuTypes: [UInt32]) -> Data {
    var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
    withUnsafeBytes(of: UInt32(cpuTypes.count).bigEndian) { data.append(contentsOf: $0) }
    for cpuType in cpuTypes {
      withUnsafeBytes(of: cpuType.bigEndian) { data.append(contentsOf: $0) }
      data.append(Data(count: 16))
    }
    return data
  }

  @Test("A thin binary names its one architecture")
  func thinBinary() {
    #expect(
      MachOArchitectures(header: thin(cpuType: MachOArchitectures.x86))?.cpuTypes
        == [MachOArchitectures.x86])
    #expect(
      MachOArchitectures(header: thin(cpuType: MachOArchitectures.arm64))?.cpuTypes
        == [MachOArchitectures.arm64])
  }

  @Test("A universal binary names every slice")
  func universalBinary() {
    let header = fat(cpuTypes: [MachOArchitectures.x86, MachOArchitectures.arm64])
    #expect(
      MachOArchitectures(header: header)?.cpuTypes
        == [MachOArchitectures.x86, MachOArchitectures.arm64])
  }

  @Test("A script, a Java class file and a truncated header are not read as binaries")
  func notAMachO() {
    #expect(MachOArchitectures(header: Data("#!/usr/bin/env node\n".utf8)) == nil)
    // Java class files open with the same magic, then a version where the slice count would be.
    let javaClass = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41])
    #expect(MachOArchitectures(header: javaClass) == nil)
    #expect(MachOArchitectures(header: Data([0xCF, 0xFA])) == nil)
  }
}
