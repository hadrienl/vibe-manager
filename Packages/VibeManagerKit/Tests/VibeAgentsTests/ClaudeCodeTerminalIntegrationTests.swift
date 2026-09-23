import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminal

@testable import VibeAgents

/// Exercises detection, argument building and a real pseudo terminal end to end, against a
/// stand in that only prints what it was given. The real `claude` is never started, no account
/// is used and no request is ever billed.
@Suite("Claude Code launch through a terminal")
struct ClaudeCodeTerminalIntegrationTests {
  private static let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "2.1.278 (Claude Code)"; exit 0; fi
    if [ "$1" = "auth" ]; then echo '{"loggedIn":true}'; exit 0; fi
    echo "cwd:$(pwd)"
    for argument in "$@"; do printf 'arg:%s\\n' "$argument"; done
    echo "done"
    """

  private func makeFakeClaude() throws -> (directory: URL, environment: [String: String]) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("claude-bin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("claude")
    try Self.script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    return (
      directory,
      [
        // The home directory is the temporary one on purpose: a real `claude` installed under
        // the developer's home must never be picked up by this test.
        "PATH": directory.path,
        "HOME": directory.path,
        "LANG": "en_US.UTF-8",
      ]
    )
  }

  private func provider(
    environment: [String: String],
    directory: URL,
    identifier: UUID
  ) -> ClaudeCodeAgentProvider {
    let probe = SystemProcessProbe()
    // The real specification, narrowed to the directory holding the stand in, so detection is
    // exercised for real without any chance of finding the developer's own installation.
    let specification = ClaudeCodeAgentProvider.specification.narrowed(
      toCandidateDirectories: [directory.path]
    )

    return ClaudeCodeAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: ClaudeCodeAgentProvider.descriptor,
        specification: specification,
        models: [],
        argumentBuilder: ClaudeCodeArgumentBuilder(makeIdentifier: { identifier }),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: ClaudeCodeAgentProvider.descriptor,
          specification: specification,
          locator: FileSystemExecutableLocator(environment: environment, probe: probe),
          probe: probe,
          environment: environment
        ),
        environment: environment
      ),
      catalog: ClaudeCodeModelCatalog(directory: URL(fileURLWithPath: "/nonexistent"))
    )
  }

  private func run(_ plan: AgentLaunchPlan) async throws -> String {
    let supervisor = PTYTerminalSupervisor()
    let session = try await supervisor.start(
      TerminalSpec(
        executableURL: plan.executableURL,
        arguments: plan.arguments,
        environment: TerminalEnvironment.make(inheriting: plan.environment),
        workingDirectoryURL: plan.workingDirectoryURL
      ),
      for: SessionID()
    )

    let attachment = await session.attach()
    // What the process wrote before the attachment is in its history, not in its events.
    var bytes = attachment.history.bytes
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(10))
      await session.kill()
    }
    defer { watchdog.cancel() }

    for await event in attachment.events {
      switch event {
      case .output(let chunk):
        bytes.append(contentsOf: chunk)
      default:
        // The stream ends by itself once the session finalizes.
        break
      }
    }
    await supervisor.stopAll(gracePeriod: .seconds(1))
    return String(decoding: bytes, as: UTF8.self)
  }

  /// A pseudo terminal turns every newline into a carriage return plus newline.
  private func lines(of output: String) -> [String] {
    output.replacingOccurrences(of: "\r\n", with: "\n")
      .split(whereSeparator: \.isNewline)
      .map(String.init)
  }

  @Test("A difficult prompt reaches the process as one untouched argument")
  func launchesWithDifficultPrompt() async throws {
    let fake = try makeFakeClaude()
    defer { try? FileManager.default.removeItem(at: fake.directory) }

    let workingDirectory = fake.directory.appendingPathComponent("un projet ☕️", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

    let identifier = UUID()
    let prompt = "Corrige \"le\" test $(rm -rf /) --now; echo pwned | cat"
    let plan = try await provider(
      environment: fake.environment, directory: fake.directory, identifier: identifier
    ).launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: workingDirectory.path,
        modelID: "claude-opus-5",
        initialPrompt: prompt
      )
    )

    let lines = lines(of: try await run(plan))
    #expect(lines.contains("arg:--session-id"))
    #expect(lines.contains("arg:\(identifier.uuidString.lowercased())"))
    #expect(lines.contains("arg:--model"))
    #expect(lines.contains("arg:claude-opus-5"))
    #expect(lines.contains("arg:--"))
    // The prompt arrived whole: no shell expanded it, no quote was lost.
    #expect(lines.contains("arg:\(prompt)"))
    #expect(!lines.contains("pwned"))
    #expect(lines.last == "done")

    // The CLI has no directory option, so the process really has to start in the session
    // directory: that is what decides where the conversation is written.
    let reportedCWD = lines.first { $0.hasPrefix("cwd:") }.map { String($0.dropFirst(4)) }
    #expect(
      reportedCWD.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        == URL(fileURLWithPath: workingDirectory.path).resolvingSymlinksInPath().path
    )
  }

  @Test("The identifier the launch assigned is the one a session can be resumed with")
  func assignsThenResumes() async throws {
    let fake = try makeFakeClaude()
    defer { try? FileManager.default.removeItem(at: fake.directory) }

    let identifier = UUID()
    let provider = provider(
      environment: fake.environment, directory: fake.directory, identifier: identifier)
    let first = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: fake.directory.path))

    let assigned = ClaudeCodeArgumentBuilder.assignedSessionIdentifier(in: first.arguments)
    #expect(assigned == identifier.uuidString.lowercased())

    let second = try await provider.launchPlan(
      for: AgentLaunchRequest(
        workingDirectoryPath: fake.directory.path,
        resume: .identifier(assigned ?? "")
      )
    )

    let lines = lines(of: try await run(second))
    #expect(lines.contains("arg:--resume"))
    #expect(lines.contains("arg:\(identifier.uuidString.lowercased())"))
    #expect(!lines.contains("arg:--session-id"))
    #expect(lines.last == "done")
  }
}
