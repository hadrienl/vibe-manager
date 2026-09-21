import Foundation
import VibeAgents
import VibeApplication

/// In memory file system: detection tests never touch the real machine.
struct StubFileSystem: ExecutableFileSystem {
  var executables: Set<String> = []
  var nonExecutableFiles: Set<String> = []
  var symlinks: [String: String] = [:]

  func fileExists(atPath path: String) -> Bool {
    let resolved = resolvedPath(for: path)
    return executables.contains(resolved) || nonExecutableFiles.contains(resolved)
  }

  func isExecutableFile(atPath path: String) -> Bool {
    executables.contains(resolvedPath(for: path))
  }

  func resolvedPath(for path: String) -> String {
    symlinks[path] ?? path
  }
}

/// Scripted probe: every call is recorded, every answer is declared up front.
final class StubProcessProbe: ProcessProbe, @unchecked Sendable {
  struct Invocation: Sendable, Equatable {
    let executablePath: String
    let arguments: [String]
  }

  private let lock = NSLock()
  private var responses: [String: Result<ProbeResult, ProbeError>]
  private var recorded: [Invocation] = []
  private let defaultResponse: Result<ProbeResult, ProbeError>

  init(
    responses: [String: Result<ProbeResult, ProbeError>] = [:],
    defaultResponse: Result<ProbeResult, ProbeError> = .success(ProbeResult(exitCode: 0))
  ) {
    self.responses = responses
    self.defaultResponse = defaultResponse
  }

  var invocations: [Invocation] {
    lock.withLock { recorded }
  }

  func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeout: Duration
  ) async throws -> ProbeResult {
    let response = lock.withLock {
      recorded.append(Invocation(executablePath: executablePath, arguments: arguments))
      return responses[executablePath] ?? defaultResponse
    }

    switch response {
    case .success(let result): return result
    case .failure(let error): throw error
    }
  }
}

struct StubLocator: ExecutableLocator {
  let location: ExecutableLocation

  func locate(_ plan: ExecutableSearchPlan) async -> ExecutableLocation {
    location
  }
}

/// Counts how many detections actually happened, to prove the cache works.
final class CountingLocator: ExecutableLocator, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let location: ExecutableLocation
  private let delay: Duration

  init(location: ExecutableLocation, delay: Duration = .zero) {
    self.location = location
    self.delay = delay
  }

  var invocationCount: Int {
    lock.withLock { count }
  }

  func locate(_ plan: ExecutableSearchPlan) async -> ExecutableLocation {
    lock.withLock { count += 1 }
    if delay != .zero {
      try? await Task.sleep(for: delay)
    }
    return location
  }
}

/// A clock the test moves forward by hand, to exercise cache expiry deterministically.
final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(start: Date) {
    current = start
  }

  var now: Date {
    lock.withLock { current }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { current = current.addingTimeInterval(interval) }
  }
}

struct PassthroughArgumentBuilder: CommandLineAgentArgumentBuilder {
  func arguments(
    for request: AgentLaunchRequest,
    promptDelivery: PromptDelivery,
    descriptor: AgentDescriptor
  ) throws -> [String] {
    var arguments: [String] = []
    if let modelID = request.modelID {
      arguments.append(contentsOf: ["--model", modelID])
    }
    if case .identifier(let identifier) = request.resume {
      arguments.append(contentsOf: ["--resume", identifier])
    }
    switch promptDelivery {
    case .none:
      break
    case .argument:
      arguments.append(contentsOf: ["--prompt", request.initialPrompt ?? ""])
    case .standardInput:
      arguments.append("--prompt-from-stdin")
    }
    return arguments
  }
}

enum TestFixtures {
  static let descriptor = AgentDescriptor(
    id: AgentProviderID("stub"),
    displayName: "Stub Agent",
    minimumVersion: AgentVersion(major: 2, minor: 0, patch: 0),
    capabilities: AgentCapabilities(
      supportsModelSelection: true,
      supportsInitialPrompt: true,
      supportsResume: true
    )
  )

  static let models = [
    AgentModel(id: "fast", displayName: "Fast", isDefault: true),
    AgentModel(id: "deep", displayName: "Deep"),
  ]

  static let specification = CommandLineAgentSpecification(
    binaryName: "stub-agent",
    candidateDirectories: ["/opt/homebrew/bin"],
    versionArguments: ["--version"]
  )

  static let installation = AgentInstallation(
    executablePath: "/opt/homebrew/bin/stub-agent",
    version: AgentVersion(major: 2, minor: 1, patch: 0),
    source: .candidateDirectory,
    detectedAt: Date(timeIntervalSince1970: 0)
  )

  static func provider(
    locator: any ExecutableLocator,
    probe: any ProcessProbe,
    environment: [String: String] = ["PATH": "/usr/bin", "HOME": "/Users/test"],
    descriptor: AgentDescriptor = TestFixtures.descriptor
  ) -> CommandLineAgentProvider {
    CommandLineAgentProvider(
      descriptor: descriptor,
      specification: specification,
      models: models,
      argumentBuilder: PassthroughArgumentBuilder(),
      availabilityProbe: AgentAvailabilityProbe(
        descriptor: descriptor,
        specification: specification,
        locator: locator,
        probe: probe,
        environment: environment,
        now: { Date(timeIntervalSince1970: 0) }
      ),
      environment: environment
    )
  }
}
