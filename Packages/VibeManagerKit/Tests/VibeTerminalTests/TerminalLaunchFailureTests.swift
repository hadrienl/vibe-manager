import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeTerminalTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func start(_ spec: TerminalSpec) throws -> PTYTerminalSession {
  try PTYTerminalSession.start(id: SessionID(), spec: spec)
}

@Test("A missing executable is reported as such")
func reportsMissingExecutable() throws {
  let spec = TerminalSpec(
    executableURL: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary"),
    workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  )

  #expect(throws: TerminalError.executableNotFound(path: spec.executableURL.path)) {
    _ = try start(spec)
  }
}

@Test("A directory is not mistaken for an executable")
func reportsDirectoryAsNotExecutable() throws {
  let spec = TerminalSpec(
    executableURL: URL(fileURLWithPath: "/usr/bin"),
    workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  )

  #expect(throws: TerminalError.notExecutable(path: "/usr/bin")) {
    _ = try start(spec)
  }
}

@Test("A file without execute permission is reported as not permitted")
func reportsFileWithoutExecutePermission() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("script.sh")
  try "#!/bin/sh\necho hi\n".write(to: file, atomically: true, encoding: .utf8)

  let spec = TerminalSpec(executableURL: file, workingDirectoryURL: directory)

  #expect(throws: TerminalError.executableNotPermitted(path: file.path)) {
    _ = try start(spec)
  }
}

@Test("A missing working directory is reported before the process is spawned")
func reportsMissingWorkingDirectory() throws {
  let directory = URL(fileURLWithPath: "/tmp/vibe-manager-missing-\(UUID().uuidString)")
  let spec = TerminalSpec(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "echo hi"],
    workingDirectoryURL: directory
  )

  #expect(throws: TerminalError.workingDirectoryUnavailable(path: directory.path)) {
    _ = try start(spec)
  }
}

@Test("Each launch failure carries a message and a remediation")
func launchFailuresAreActionable() {
  let failures: [TerminalError] = [
    .executableNotFound(path: "/bin/nope"),
    .executableNotPermitted(path: "/bin/nope"),
    .notExecutable(path: "/bin/nope"),
    .workingDirectoryUnavailable(path: "/nope"),
    .pseudoTerminalUnavailable(code: EAGAIN),
    .resourceLimitReached(code: EAGAIN),
    .spawnFailed(code: EINVAL),
    .sessionAlreadyRunning(SessionID()),
  ]

  for failure in failures {
    #expect(failure.errorDescription?.isEmpty == false)
    #expect(failure.recoverySuggestion?.isEmpty == false)
  }
}

@Test("The working directory of the process is the one that was requested")
func runsInTheRequestedWorkingDirectory() async throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = directory.appendingPathComponent("marker.txt")
  try "present".write(to: marker, atomically: true, encoding: .utf8)

  let session = try start(
    TerminalTestSupport.spec(script: "cat marker.txt", workingDirectory: directory)
  )
  let outcome = await runToCompletion(session)

  #expect(outcome.text.contains("present"))
  #expect(outcome.state == .exited(code: 0))
}
