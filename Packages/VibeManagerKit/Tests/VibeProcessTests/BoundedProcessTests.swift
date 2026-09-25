import Darwin
import Foundation
import Testing

@testable import VibeProcess

@Suite("Bounded process")
struct BoundedProcessTests {
  private func shell(
    _ script: String,
    environment: [String: String] = ["PATH": "/usr/bin:/bin"],
    timeout: Duration = .seconds(10),
    outputByteLimit: Int = BoundedProcess.defaultOutputByteLimit,
    grace: Duration = .milliseconds(300)
  ) -> BoundedProcessRequest {
    BoundedProcessRequest(
      executablePath: "/bin/sh",
      arguments: ["-c", script],
      environment: environment,
      timeout: timeout,
      outputByteLimit: outputByteLimit,
      terminationGrace: grace
    )
  }

  private func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether a process of this pid is alive, a zombie counting as gone.
  private func isAlive(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(
      pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return size > 0 && info.pbi_status != UInt32(SZOMB)
  }

  private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
  }

  @Test("It captures both streams and the exit status")
  func capturesOutput() async throws {
    let result = try await BoundedProcess.run(shell("echo out; echo err >&2; exit 3"))

    #expect(result.termination == .exited(3))
    #expect(text(result.standardOutput) == "out")
    #expect(text(result.standardError) == "err")
    #expect(!result.outputTruncated)
  }

  @Test("A command a signal ends reports the signal")
  func reportsSignal() async throws {
    let result = try await BoundedProcess.run(shell("kill -KILL $$"))

    #expect(result.termination == .signalled(SIGKILL))
  }

  @Test("The environment is exactly the one given: nothing of the application leaks")
  func explicitEnvironment() async throws {
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/env", arguments: [], environment: ["ONLY": "this"],
        timeout: .seconds(5)))

    #expect(text(result.standardOutput) == "ONLY=this")
  }

  @Test("Standard input is /dev/null and no other descriptor is inherited")
  func descriptors() async throws {
    // A descriptor the test leaves inheritable, far from any the shell would open: the child
    // must not see it.
    let opened = open("/dev/null", O_RDONLY)
    let leaked = dup2(opened, 200)
    close(opened)
    defer { close(leaked) }
    #expect(leaked == 200)

    let result = try await BoundedProcess.run(
      shell("read line; echo \"read=$?\"; [ -e /dev/fd/200 ] && echo leaked; true"))
    let lines = text(result.standardOutput).split(separator: "\n").map(String.init)

    #expect(lines == ["read=1"])
  }

  @Test("The command leads a process group of its own, registered while it runs")
  func ownGroup() async throws {
    let result = try await BoundedProcess.run(shell("/bin/ps -o pid= -o pgid= -p $$"))
    let fields = text(result.standardOutput).split(separator: " ").compactMap { Int32($0) }

    #expect(fields.count == 2)
    #expect(fields.first == fields.last)
    #expect(fields.first != getpgrp())
    #expect(!ChildProcessGroupGuard.isRegistered(fields[0]))
  }

  @Test("A timeout stops the whole group, a grandchild that ignores SIGTERM included")
  func timeoutStopsGroup() async throws {
    let result = try await BoundedProcess.run(
      shell(
        "(trap '' TERM; sleep 30) & echo $!; trap '' TERM; sleep 30",
        timeout: .milliseconds(300)
      )
    )

    #expect(result.didTimeOut)
    let grandchild = try #require(Int32(text(result.standardOutput)))
    #expect(await eventually { !isAlive(grandchild) })
  }

  @Test("What a command leaves in its group when it exits is stopped with it")
  func sweepsLeftovers() async throws {
    let result = try await BoundedProcess.run(
      shell("(trap '' HUP; sleep 30) >/dev/null 2>&1 & echo $!; exit 0"))

    #expect(result.termination == .exited(0))
    let grandchild = try #require(Int32(text(result.standardOutput)))
    #expect(await eventually { !isAlive(grandchild) })
  }

  @Test("Cancelling the task stops the group instead of waiting for the timeout")
  func cancellation() async throws {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-bounded-\(UUID().uuidString)")
    let request = shell("trap '' TERM; sleep 30; touch '\(marker.path)'", timeout: .seconds(30))
    let task = Task { try await BoundedProcess.run(request) }

    try await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()

    await #expect(throws: BoundedProcessError.cancelled) { try await task.value }
    // Well under the 30 seconds of the timeout; 5 seconds measured the runner's load, and failed
    // at 6 on a busy one.
    #expect(clock.now - start < .seconds(20))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Output beyond the limit is drained, dropped and reported")
  func truncates() async throws {
    let result = try await BoundedProcess.run(
      shell(
        "i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done",
        outputByteLimit: 4096
      )
    )

    #expect(result.termination == .exited(0))
    #expect(result.standardOutput.count == 4096)
    #expect(result.outputTruncated)
  }

  @Test("A missing executable or working directory is a launch failure, with its code")
  func launchFailure() async {
    await #expect(throws: BoundedProcessError.launchFailed(code: ENOENT)) {
      try await BoundedProcess.run(
        BoundedProcessRequest(
          executablePath: "/nonexistent/binary", arguments: [], environment: [:],
          timeout: .seconds(1)))
    }
    await #expect(throws: BoundedProcessError.launchFailed(code: ENOENT)) {
      try await BoundedProcess.run(
        BoundedProcessRequest(
          executablePath: "/bin/echo", arguments: [], environment: [:],
          workingDirectoryPath: "/nonexistent/folder", timeout: .seconds(1)))
    }
  }

  @Test("The working directory is the one given")
  func workingDirectory() async throws {
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/bin/pwd", arguments: [], environment: [:],
        workingDirectoryPath: "/usr/bin", timeout: .seconds(5)))

    #expect(text(result.standardOutput) == "/usr/bin")
  }
}
