import Darwin
import Foundation
import Testing
import VibeApplication

@testable import VibeTerminal

@Suite("Reading a side terminal's shell from the kernel", .timeLimit(.minutes(1)))
struct ShellProcessInspectorTests {
  /// An interactive shell with job control, the way a side terminal runs one, without the
  /// user's configuration.
  private func interactiveShell(in directory: URL) -> TerminalSpec {
    TerminalSpec(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-f", "-i"],
      environment: TerminalEnvironment.make(),
      workingDirectoryURL: directory,
      role: .auxiliary)
  }

  @Test("The folder a shell moved to, and the command it runs in the foreground, then none")
  func followsTheShell() async throws {
    // Started through the trampoline, as a side terminal is: job control needs a controlling
    // terminal, which only the child can take.
    ControllingTerminal.useTrampoline(at: try TerminalHostProcessTests.fixtureURL().path)
    let supervisor = PTYTerminalSupervisor()
    let start = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeInspector-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let session = try await supervisor.start(interactiveShell(in: start), for: TerminalID())
    defer { Task { await supervisor.stopAll(gracePeriod: .milliseconds(200)) } }
    var pid: Int32?
    _ = await eventually {
      if case .running(let identifier) = await session.state() { pid = identifier }
      return pid != nil
    }
    guard let shell = pid else {
      Issue.record("The shell did not start: \(await session.state())")
      return
    }
    let inspector = DarwinShellProcessInspector()
    // `/var` is `/private/var`: both sides are compared resolved.
    let expected = destination.resolvingSymlinksInPath().path

    await session.write("cd '\(destination.path)'\r")
    var last: ShellProcessSnapshot?
    let moved = await eventually {
      last = await inspector.inspect(processIdentifier: shell)
      return last?.currentDirectory.map {
        URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
      } == expected
    }
    #expect(moved, "last seen in \(last?.currentDirectory ?? "nothing")")

    await session.write("sleep 30\r")
    #expect(
      await eventually {
        await inspector.inspect(processIdentifier: shell)?.foregroundCommand == "sleep 30"
      })

    // ⌃C: back at the prompt.
    await session.write([0x03])
    #expect(
      await eventually {
        let snapshot = await inspector.inspect(processIdentifier: shell)
        return snapshot != nil && snapshot?.foregroundCommand == nil
      })
  }

  @Test(
    "Stopping a side terminal stops what its shell runs, in the foreground and in the background")
  func stopLeavesNothingBehind() async throws {
    ControllingTerminal.useTrampoline(at: try TerminalHostProcessTests.fixtureURL().path)
    let supervisor = PTYTerminalSupervisor()
    let session = try await supervisor.start(
      interactiveShell(in: FileManager.default.temporaryDirectory), for: TerminalID())
    var pid: Int32?
    _ = await eventually {
      if case .running(let identifier) = await session.state() { pid = identifier }
      return pid != nil
    }
    let shell = try #require(pid)

    await session.write("sleep 301 &\r")
    await session.write("sleep 302\r")
    var foreground: pid_t = 0
    #expect(
      await eventually {
        foreground = Self.foregroundGroup(of: shell)
        return foreground > 0 && foreground != shell
      })
    var jobs: [pid_t] = []
    #expect(
      await eventually {
        jobs = Self.children(of: shell)
        return jobs.count == 2
      })

    await session.stop(gracePeriod: .seconds(2))

    #expect(await eventually { kill(-foreground, 0) != 0 })
    for job in jobs {
      #expect(await eventually { kill(job, 0) != 0 }, "job \(job) still runs")
    }
    #expect(kill(shell, 0) != 0)
  }

  @Test("A shell's jobs are found by its terminal session, older processes left out")
  func findsTheJobsOfAShell() async throws {
    ControllingTerminal.useTrampoline(at: try TerminalHostProcessTests.fixtureURL().path)
    let supervisor = PTYTerminalSupervisor()
    let startedAt = Date()
    let session = try await supervisor.start(
      interactiveShell(in: FileManager.default.temporaryDirectory), for: TerminalID())
    defer { Task { await supervisor.stopAll(gracePeriod: .milliseconds(200)) } }
    var pid: Int32?
    _ = await eventually {
      if case .running(let identifier) = await session.state() { pid = identifier }
      return pid != nil
    }
    let shell = try #require(pid)
    let probe = SystemProcessLivenessProbe()

    await session.write("sleep 303 &\r")
    var jobs: [pid_t] = []
    #expect(
      await eventually {
        jobs = Self.children(of: shell)
        return jobs.count == 1
      })
    let job = try #require(jobs.first)

    #expect(
      await eventually {
        probe.jobGroups(inSessionOf: shell, startedSince: startedAt) == [getpgid(job)]
      })
    // Everything in it is newer than that: none of it is taken for the shell's.
    #expect(
      probe.jobGroups(inSessionOf: shell, startedSince: Date().addingTimeInterval(60)).isEmpty)
  }

  private static func foregroundGroup(of pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
    return pid_t(bitPattern: info.e_tpgid)
  }

  private static func children(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 64)
    let count = proc_listchildpids(
      pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return Array(buffer.prefix(max(0, Int(count))))
  }

  @Test("The trampoline refuses to run anything outside a terminal it leads")
  func trampolineRefusesOutsideATerminal() throws {
    let process = Process()
    process.executableURL = try TerminalHostProcessTests.fixtureURL()
    process.arguments = [ControllingTerminal.argument, "/bin/echo", "echo", "ran"]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 126)
    #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
  }

  @Test("A process that is gone says nothing")
  func goneProcess() async {
    #expect(await DarwinShellProcessInspector().inspect(processIdentifier: 0) == nil)
    #expect(await DarwinShellProcessInspector().inspect(processIdentifier: -1) == nil)
  }

  @Test("A command is titled as typed: the script an interpreter runs, not the interpreter")
  func commandTitles() {
    #expect(
      CommandTitle.make(["/usr/local/bin/node", "/usr/local/bin/npm", "run", "dev"])
        == "npm run dev")
    #expect(CommandTitle.make(["python3", "-m", "http.server"]) == "python3 -m http.server")
    #expect(CommandTitle.make(["/usr/bin/vim", "README.md"]) == "vim README.md")
    #expect(CommandTitle.make([]) == nil)
    let long = CommandTitle.make(["tail", "-f", String(repeating: "x", count: 80)])
    #expect(long?.count == CommandTitle.maximumLength)
    #expect(long?.hasSuffix("…") == true)
  }
}
