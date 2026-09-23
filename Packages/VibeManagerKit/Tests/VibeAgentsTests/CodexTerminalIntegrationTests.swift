import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeTerminal

@testable import VibeAgents

/// Runs the whole chain — detection, launch plan, pseudo terminal — against a stand in that
/// answers like the Codex CLI. It proves that the arguments a provider builds reach a process
/// unchanged, which no unit test on `argv` alone can establish.
///
/// Nothing here contacts OpenAI: the executable is a shell script written for the test.
@Suite("Codex launch through a terminal")
struct CodexTerminalIntegrationTests {
  private static let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "codex-cli 0.155.1"; exit 0; fi
    if [ "$1" = "login" ] && [ "$2" = "status" ]; then echo "Logged in"; exit 0; fi
    echo "cwd:$(pwd)"
    for argument in "$@"; do printf 'arg:%s\\n' "$argument"; done
    echo "done"
    """

  private func makeFakeCodex() throws -> (directory: URL, environment: [String: String]) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codex-bin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex")
    try Self.script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)

    return (
      directory,
      [
        // The home directory is the temporary one on purpose: a real `codex` installed under
        // the developer's home must never be picked up by this test.
        "PATH": directory.path,
        "HOME": directory.path,
        "LANG": "en_US.UTF-8",
      ]
    )
  }

  private func provider(environment: [String: String], directory: URL) -> CodexAgentProvider {
    let probe = SystemProcessProbe()
    // The real specification, narrowed to the directory holding the stand in, so detection is
    // exercised for real without any chance of finding the developer's own installation.
    let specification = CodexAgentProvider.specification.narrowed(
      toCandidateDirectories: [directory.path]
    )

    return CodexAgentProvider(
      base: CommandLineAgentProvider(
        descriptor: CodexAgentProvider.descriptor,
        specification: specification,
        models: [],
        argumentBuilder: CodexArgumentBuilder(),
        availabilityProbe: AgentAvailabilityProbe(
          descriptor: CodexAgentProvider.descriptor,
          specification: specification,
          locator: FileSystemExecutableLocator(environment: environment, probe: probe),
          probe: probe,
          environment: environment
        ),
        environment: environment
      ),
      catalog: CodexModelCatalog(cacheURL: URL(fileURLWithPath: "/nonexistent/models_cache.json")),
      discovery: CodexRolloutSessionDiscovery(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions"))
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
    let fake = try makeFakeCodex()
    defer { try? FileManager.default.removeItem(at: fake.directory) }

    let workingDirectory = fake.directory.appendingPathComponent("un projet ☕️", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

    let prompt = "Corrige \"le\" test $(rm -rf /) --now; echo pwned | cat"
    let plan = try await provider(environment: fake.environment, directory: fake.directory)
      .launchPlan(
        for: AgentLaunchRequest(
          workingDirectoryPath: workingDirectory.path,
          modelID: "gpt-6-astra",
          initialPrompt: prompt
        )
      )

    let lines = lines(of: try await run(plan))
    #expect(lines.contains("arg:-m"))
    #expect(lines.contains("arg:gpt-6-astra"))
    #expect(lines.contains("arg:-C"))
    #expect(lines.contains("arg:\(workingDirectory.path)"))
    #expect(lines.contains("arg:--"))
    // The prompt arrived whole: no shell expanded it, no quote was lost.
    #expect(lines.contains("arg:\(prompt)"))
    #expect(!lines.contains("pwned"))
    #expect(lines.last == "done")

    let reportedCWD = lines.first { $0.hasPrefix("cwd:") }.map { String($0.dropFirst(4)) }
    #expect(
      reportedCWD.map(CodexRolloutSessionDiscovery.canonicalPath)
        == CodexRolloutSessionDiscovery.canonicalPath(workingDirectory.path)
    )
  }

  @Test("Resuming hands the identifier to the resume subcommand")
  func resumesSession() async throws {
    let fake = try makeFakeCodex()
    defer { try? FileManager.default.removeItem(at: fake.directory) }

    let identifier = "019ee0a1-06d9-7e52-957b-d61a982d6b43"
    let plan = try await provider(environment: fake.environment, directory: fake.directory)
      .launchPlan(
        for: AgentLaunchRequest(
          workingDirectoryPath: fake.directory.path,
          resume: .identifier(identifier)
        )
      )

    let lines = lines(of: try await run(plan))
    #expect(lines.contains("arg:resume"))
    #expect(lines.contains("arg:\(identifier)"))
    #expect(!lines.contains("arg:--last"))
  }
}
