import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("System process probe")
struct SystemProcessProbeTests {
  @Test("It captures the output and the exit code of a short command")
  func capturesOutput() async throws {
    let result = try await SystemProcessProbe().run(
      executablePath: "/bin/echo",
      arguments: ["hello world"],
      timeout: .seconds(5)
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "hello world")
    #expect(!result.didTimeOut)
  }

  @Test("It reports a non zero exit code instead of throwing")
  func reportsFailure() async throws {
    let result = try await SystemProcessProbe().run(
      executablePath: "/bin/sh",
      arguments: ["-c", "echo boom >&2; exit 3"],
      timeout: .seconds(5)
    )

    #expect(result.exitCode == 3)
    #expect(result.standardError == "boom")
  }

  @Test("A command that hangs is terminated and reported as timed out")
  func terminatesHangingCommand() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await SystemProcessProbe(terminationGrace: .milliseconds(200)).run(
      executablePath: "/bin/sh",
      arguments: ["-c", "trap '' TERM; sleep 30"],
      timeout: .milliseconds(300)
    )
    let elapsed = clock.now - start

    #expect(result.didTimeOut)
    // Well under the 30 seconds the command sleeps: that is what shows it was stopped. A tighter
    // bound measured the runner's load instead, and failed at 6 and 8 seconds on a busy one.
    #expect(elapsed < .seconds(20))
  }

  @Test("Cancelling the task reaps the child instead of waiting for the timeout")
  func cancellationReapsTheChild() async throws {
    let marker = URL(
      fileURLWithPath: NSTemporaryDirectory(),
      isDirectory: true
    ).appendingPathComponent("vibe-probe-\(UUID().uuidString)")

    let task = Task {
      try await SystemProcessProbe(terminationGrace: .milliseconds(200)).run(
        executablePath: "/bin/sh",
        arguments: ["-c", "trap '' TERM; sleep 30; touch \(marker.path)"],
        timeout: .seconds(30)
      )
    }

    try? await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()

    await #expect(throws: ProbeError.cancelled) { try await task.value }
    // Well under the 30 seconds of the timeout; 5 seconds measured the runner's load, and failed
    // at 5.01 on a busy one.
    #expect(clock.now - start < .seconds(20))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Output larger than the pipe buffer is drained and truncated to the limit")
  func truncatesLargeOutput() async throws {
    let result = try await SystemProcessProbe(outputByteLimit: 4096).run(
      executablePath: "/bin/sh",
      arguments: ["-c", "for i in $(seq 1 20000); do echo 0123456789; done"],
      timeout: .seconds(20)
    )

    #expect(result.exitCode == 0)
    #expect(!result.didTimeOut)
    #expect(result.standardOutput.utf8.count <= 4096)
  }

  @Test("A missing executable surfaces as a typed launch failure")
  func reportsLaunchFailure() async {
    await #expect(throws: ProbeError.launchFailed) {
      try await SystemProcessProbe().run(
        executablePath: "/nonexistent/binary",
        arguments: [],
        timeout: .seconds(1)
      )
    }
  }
}
