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
  try PTYTerminalSession.start(id: TerminalID(), spec: spec)
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
    .sessionAlreadyRunning(TerminalID()),
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

@Test("A trampoline that no longer exists starts the shell directly, not a false missing shell")
func missingTrampolineFallsBackToTheShell() throws {
  // The terminal host outlived the build it was started from (#382): spawning the trampoline
  // failed with ENOENT, reported as "No executable was found at /bin/zsh".
  let gone = "/tmp/vibe-manager-gone-\(UUID().uuidString)/Vibe Manager"
  #expect(
    ControllingTerminal.arguments(for: "/bin/zsh", arguments: ["-l"], trampoline: gone) == nil)

  let present = try #require(
    ControllingTerminal.arguments(for: "/bin/zsh", arguments: ["-l"], trampoline: "/bin/sh"))
  #expect(present.0 == "/bin/sh")
  #expect(present.1 == ["/bin/sh", ControllingTerminal.argument, "/bin/zsh", "/bin/zsh", "-l"])
}

@Test("A side terminal started without its trampoline is said in the host's log, once per start")
func missingTrampolineIsLogged() {
  let log = RecordingDiagnosticLog()
  let diagnostics = Diagnostics(log: log, pseudonym: .ephemeral())
  let gone = "/tmp/vibe-manager-gone-\(UUID().uuidString)/Vibe Manager"
  var shell = TerminalSpec(
    executableURL: URL(fileURLWithPath: "/bin/zsh"),
    workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
    role: .auxiliary)

  TerminalHostServer.noteMissingTrampoline(
    for: shell, id: TerminalID(), trampoline: gone, diagnostics: diagnostics)
  #expect(log.events(named: "host.trampolineMissing").count == 1)
  #expect(log.events(named: "host.trampolineMissing").first?.fields.count == 1)

  // Nothing to say with a trampoline that runs, with none at all, or for an agent.
  TerminalHostServer.noteMissingTrampoline(
    for: shell, id: TerminalID(), trampoline: "/bin/sh", diagnostics: diagnostics)
  TerminalHostServer.noteMissingTrampoline(
    for: shell, id: TerminalID(), trampoline: nil, diagnostics: diagnostics)
  shell.role = .agent
  TerminalHostServer.noteMissingTrampoline(
    for: shell, id: TerminalID(), trampoline: gone, diagnostics: diagnostics)
  #expect(log.events(named: "host.trampolineMissing").count == 1)
}
