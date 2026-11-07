import Foundation
import Testing

@testable import VibeProcess

@Suite("Streaming process")
struct StreamingProcessTests {
  private static let environment = ["PATH": "/usr/bin:/bin"]

  @Test("What it is given comes back from it, in its own group, until its input closes")
  func echoes() async throws {
    let process = try StreamingProcess(
      executablePath: "/bin/cat", arguments: [], environment: Self.environment)
    #expect(getpgid(process.processIdentifier) == process.processIdentifier)
    #expect(ChildProcessGroupGuard.isRegistered(process.processIdentifier))
    try process.input.write(contentsOf: Data("ping\n".utf8))
    try process.input.close()
    let echoed = try process.output.readToEnd()
    #expect(echoed == Data("ping\n".utf8))
    try await waitUntil { process.hasExited }
    #expect(!ChildProcessGroupGuard.isRegistered(process.processIdentifier))
  }

  @Test("Stopping ends a child that ignores its input, and a write afterwards only fails")
  func stops() async throws {
    let process = try StreamingProcess(
      executablePath: "/bin/sleep", arguments: ["30"], environment: Self.environment,
      terminationGrace: .milliseconds(200))
    process.stop()
    try await waitUntil { process.hasExited }
    #expect(throws: (any Error).self) {
      try process.input.write(contentsOf: Data("late\n".utf8))
    }
  }

  @Test("A missing executable is a launch failure")
  func missing() {
    #expect(throws: BoundedProcessError.self) {
      try StreamingProcess(
        executablePath: "/nonexistent/bridge", arguments: [], environment: Self.environment)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }
}
