import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeAgents

/// Runs nothing: records the request, writes what the "agent" would have, and answers.
private final class FakeRunner: SummaryProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [BoundedProcessRequest] = []
  let termination: BoundedProcessResult.Termination
  let standardError: String
  /// Written as `sheet.png` in the folder the command runs in; `nil` writes nothing.
  let image: Data?
  let asLink: Bool

  init(
    termination: BoundedProcessResult.Termination = .exited(0), standardError: String = "",
    image: Data? = Data("png".utf8), asLink: Bool = false
  ) {
    self.termination = termination
    self.standardError = standardError
    self.image = image
    self.asLink = asLink
  }

  var requests: [BoundedProcessRequest] { lock.withLock { recorded } }

  func run(_ request: BoundedProcessRequest) async throws -> BoundedProcessResult {
    lock.withLock { recorded.append(request) }
    let folder = URL(fileURLWithPath: try #require(request.workingDirectoryPath))
    let target = folder.appendingPathComponent("sheet.png")
    if asLink {
      try FileManager.default.createSymbolicLink(
        atPath: target.path, withDestinationPath: "/etc/hosts")
    } else if let image {
      try image.write(to: target)
    }
    return BoundedProcessResult(
      termination: termination, standardOutput: Data(),
      standardError: Data(standardError.utf8), outputTruncated: false)
  }
}

@Suite("Avatars drawn by Codex")
struct CodexAvatarGeneratorTests {
  private func provider() -> MockAgentProvider {
    MockAgentProvider(environment: [:])
  }

  @Test("The run is ephemeral, without the user's configuration or anything that could act")
  func arguments() {
    let arguments = CodexAvatarGenerator.arguments(withReference: false)
    #expect(arguments.starts(with: ["exec", "--ephemeral", "--skip-git-repo-check"]))
    for flag in ["--ignore-user-config", "--ignore-rules"] { #expect(arguments.contains(flag)) }
    #expect(arguments.contains("image_generation"))
    for feature in ["hooks", "apps", "plugins"] {
      #expect(arguments.contains(feature))
    }
    #expect(arguments.contains("mcp_servers={}"))
    #expect(arguments.contains("tools.web_search=false"))
    #expect(!arguments.contains("-i"))
    #expect(arguments.last == "-")
    #expect(!arguments.contains("danger-full-access"))
  }

  @Test("The prompt goes on the standard input, the reference in the run's folder")
  func reference() async throws {
    let runner = FakeRunner()
    let generator = CodexAvatarGenerator(provider: provider(), runner: runner)
    let image = try await generator.generate(
      AvatarGenerationRequest(prompt: "Draw", reference: Data("ref".utf8)))

    #expect(image == Data("png".utf8))
    let request = try #require(runner.requests.first)
    #expect(request.standardInput?.data == Data("Draw".utf8))
    #expect(request.arguments.suffix(3) == ["-i", "reference.png", "-"])
    #expect(request.timeout == CodexAvatarGenerator.timeout)
    // The folder is gone once the image is read.
    let folder = try #require(request.workingDirectoryPath)
    #expect(!FileManager.default.fileExists(atPath: folder))
  }

  @Test("No image written: said as such")
  func noImage() async {
    let generator = CodexAvatarGenerator(provider: provider(), runner: FakeRunner(image: nil))
    await #expect(throws: AvatarGenerationError.noImage) {
      try await generator.generate(AvatarGenerationRequest(prompt: "Draw"))
    }
  }

  @Test("A link in place of the image is not followed")
  func link() async {
    let generator = CodexAvatarGenerator(provider: provider(), runner: FakeRunner(asLink: true))
    await #expect(throws: AvatarGenerationError.noImage) {
      try await generator.generate(AvatarGenerationRequest(prompt: "Draw"))
    }
  }

  @Test("Out of time, too old, signed out: each said apart")
  func failures() async {
    let cases: [(FakeRunner, AvatarGenerationError)] = [
      (FakeRunner(termination: .timedOut), .timedOut),
      (
        FakeRunner(termination: .exited(2), standardError: "error: unknown feature flag"),
        .unavailable(.outdated)
      ),
      (FakeRunner(termination: .exited(1), standardError: "Not logged in"), .unavailable(.signedOut)),
      (FakeRunner(termination: .exited(1), standardError: "boom"), .failed("exit 1")),
    ]
    for (runner, expected) in cases {
      let generator = CodexAvatarGenerator(provider: provider(), runner: runner)
      await #expect(throws: expected) {
        try await generator.generate(AvatarGenerationRequest(prompt: "Draw"))
      }
    }
  }

  @Test("An agent that is not installed cannot draw")
  func unavailable() async {
    let generator = CodexAvatarGenerator(
      provider: MockAgentProvider(simulatedState: .notFound, environment: [:]), runner: FakeRunner())
    await #expect(throws: AvatarGenerationError.unavailable(.missing)) {
      try await generator.generate(AvatarGenerationRequest(prompt: "Draw"))
    }
  }
}

@Suite("Which agents draw")
struct AvatarGeneratorOptionsTests {
  @Test("Claude Code does not draw; Codex does; those that can come first")
  func options() async {
    let registry = AgentProviderRegistry(providers: [
      ClaudeCodeAgentProvider.make(environment: [:]), MockAgentProvider(environment: [:]),
    ])
    let options = await AgentAvatarGenerators(agents: registry).options()
    let claude = options.first { $0.id == ClaudeCodeAgentProvider.id }
    #expect(claude?.unavailability == .notCapable)
    #expect(claude?.generator == nil)
    #expect(options.first?.id == MockAgentProvider.id)
    #expect(CodexAgentProvider.make(environment: [:]) is any AvatarGeneratingProviding)
  }
}

/// The real Codex, signed in, over the network: opt in with `VIBE_AVATAR_INTEGRATION=1`. Each run
/// draws a sheet on the account, and takes a minute or two.
@Suite(
  "An avatar drawn by the real Codex",
  .enabled(if: ProcessInfo.processInfo.environment["VIBE_AVATAR_INTEGRATION"] == "1"))
struct AvatarIntegrationTests {
  @Test("Codex writes a sheet")
  func codex() async throws {
    let image = try await CodexAgentProvider.make().avatarGenerator().generate(
      AvatarGenerationRequest(prompt: AvatarPrompt.sheet(description: "a small green frog")))
    #expect(image.count > 1_000)
    if let folder = ProcessInfo.processInfo.environment["VIBE_AVATAR_OUTPUT"] {
      try image.write(to: URL(fileURLWithPath: folder).appendingPathComponent("sheet.png"))
    }
  }
}
