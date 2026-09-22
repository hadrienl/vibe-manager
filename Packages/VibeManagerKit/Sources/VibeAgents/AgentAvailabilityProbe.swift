import Foundation
import VibeApplication

/// Detects one agent CLI, caches the result and never lets a slow binary block a caller.
///
/// Concurrent callers share a single in flight detection instead of spawning one process each.
public actor AgentAvailabilityProbe {
  private let descriptor: AgentDescriptor
  private let specification: CommandLineAgentSpecification
  private let locator: any ExecutableLocator
  private let probe: any ProcessProbe
  private let environment: [String: String]
  private let timeToLive: Duration
  private let failureTimeToLive: Duration
  private let now: @Sendable () -> Date

  private var cached: AgentAvailability?
  private var cachedAt: Date?
  private var inFlight: Task<AgentAvailability, Never>?
  private var userDefinedPath: String?
  /// Bumped by every invalidation, so a detection started earlier cannot publish its result.
  private var generation: UInt64 = 0

  public init(
    descriptor: AgentDescriptor,
    specification: CommandLineAgentSpecification,
    locator: any ExecutableLocator,
    probe: any ProcessProbe,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeToLive: Duration = .seconds(300),
    failureTimeToLive: Duration = .seconds(20),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.descriptor = descriptor
    self.specification = specification
    self.locator = locator
    self.probe = probe
    self.environment = environment
    self.timeToLive = timeToLive
    // Holding on to a non answer longer than to a real one would be the wrong way round.
    self.failureTimeToLive = min(failureTimeToLive, timeToLive)
    self.now = now
  }

  public func setUserDefinedPath(_ path: String?) {
    userDefinedPath = path
    invalidate()
  }

  public func invalidate() {
    cached = nil
    cachedAt = nil
    // Any detection started before this point describes a configuration that no longer
    // applies, so its result must not repopulate the cache when it lands.
    generation &+= 1
    inFlight?.cancel()
    inFlight = nil
  }

  public func availability(forceRefresh: Bool) async -> AgentAvailability {
    if forceRefresh {
      // A forced refresh supersedes the detection in flight. Letting both run would leave the
      // cache to whichever finishes last, so a slow probe started before the user installed the
      // agent could overwrite the fresh result that found it.
      invalidate()
    }

    while true {
      if let cached, let cachedAt, !isExpired(cachedAt, for: cached.state) {
        return cached
      }

      let startedGeneration = generation
      if let inFlight {
        let availability = await inFlight.value
        // An invalidation while waiting means this result describes a configuration that no
        // longer applies — including the cancellation it caused, which is not a real failure.
        guard startedGeneration == generation else { continue }
        return availability
      }

      let path = userDefinedPath
      let task = Task { [specification, locator, probe, environment, descriptor, now] in
        await Self.detect(
          descriptor: descriptor,
          specification: specification,
          locator: locator,
          probe: probe,
          environment: environment,
          userDefinedPath: path,
          now: now
        )
      }
      inFlight = task
      let availability = await task.value

      // The actor can be re-entered while the detection runs: only the task that still
      // represents the current configuration is allowed to publish its result.
      guard startedGeneration == generation else { continue }
      inFlight = nil
      cached = availability
      cachedAt = now()
      return availability
    }
  }

  private func isExpired(_ date: Date, for state: AgentAvailabilityState) -> Bool {
    now().timeIntervalSince(date) >= lifetime(of: state).seconds
  }

  /// A transient failure is remembered just long enough to keep a redrawn window from spawning
  /// a process, and not long enough to outlive the slow start that caused it.
  private func lifetime(of state: AgentAvailabilityState) -> Duration {
    guard case .probeFailed(let reason) = state, reason.isTransient else { return timeToLive }
    return failureTimeToLive
  }

  private static func detect(
    descriptor: AgentDescriptor,
    specification: CommandLineAgentSpecification,
    locator: any ExecutableLocator,
    probe: any ProcessProbe,
    environment: [String: String],
    userDefinedPath: String?,
    now: @Sendable () -> Date
  ) async -> AgentAvailability {
    let hints = AgentRemediationHints(specification: specification)
    let searchPlan = ExecutableSearchPlan(
      binaryName: specification.binaryName,
      candidateDirectories: specification.candidateDirectories,
      userDefinedPath: userDefinedPath,
      allowsLoginShellFallback: true
    )

    switch await locator.locate(searchPlan) {
    case .notFound:
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .notFound,
        installation: nil,
        detail: "No \(specification.binaryName) executable was found.",
        at: now(),
        hints: hints
      )
    case .notExecutable(let path, let source):
      let installation = AgentInstallation(
        executablePath: path,
        version: nil,
        source: source,
        detectedAt: now()
      )
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .notExecutable,
        installation: installation,
        detail: "The file exists but is not executable.",
        at: now(),
        hints: hints
      )
    case .found(let path, let source):
      return await versionState(
        descriptor: descriptor,
        specification: specification,
        probe: probe,
        environment: environment,
        path: path,
        source: source,
        now: now
      )
    }
  }

  private static func versionState(
    descriptor: AgentDescriptor,
    specification: CommandLineAgentSpecification,
    probe: any ProcessProbe,
    environment: [String: String],
    path: String,
    source: AgentDetectionSource,
    now: @Sendable () -> Date
  ) async -> AgentAvailability {
    let hints = AgentRemediationHints(specification: specification)
    var outcome = await versionProbeOutcome(
      specification: specification,
      probe: probe,
      environment: environment,
      path: path,
      timeout: specification.versionTimeout
    )
    if case .timedOut = outcome {
      // A timeout is not an answer, so it is not a verdict either. The second attempt runs on a
      // wider budget and against a binary the first one has just warmed up; only its silence
      // says anything about the installation.
      outcome = await versionProbeOutcome(
        specification: specification,
        probe: probe,
        environment: environment,
        path: path,
        timeout: specification.versionRetryTimeout
      )
    }

    let result: ProbeResult
    switch outcome {
    case .answered(let answer):
      result = answer
    case .timedOut:
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .probeFailed(reason: .timedOut),
        // The path is kept: an export of a failing probe is useless without it.
        installation: located(path: path, source: source, now: now),
        detail: "\(specification.binaryName) did not answer --version in time, twice.",
        at: now(),
        hints: hints
      )
    case .cancelled:
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .probeFailed(reason: .cancelled),
        installation: located(path: path, source: source, now: now),
        detail: nil,
        at: now(),
        hints: hints
      )
    case .notStarted:
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .probeFailed(reason: .failed(exitCode: -1)),
        installation: located(path: path, source: source, now: now),
        detail: "The executable could not be started.",
        at: now(),
        hints: hints
      )
    }

    guard result.exitCode == 0 else {
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .probeFailed(reason: .failed(exitCode: result.exitCode)),
        installation: located(path: path, source: source, now: now),
        detail: "Version probe exited with code \(result.exitCode).",
        at: now(),
        hints: hints
      )
    }

    // Standard error often carries unrelated warnings, so it is only a fallback.
    let output = result.standardOutput.isEmpty ? result.combinedOutput : result.standardOutput
    // An unreadable version never disables the agent: CLIs do change their output format.
    let version = AgentVersion(parsing: output, anchor: specification.binaryName)
    let installation = AgentInstallation(
      executablePath: path,
      version: version,
      rawVersionOutput: output.isEmpty ? nil : output,
      source: source,
      detectedAt: now()
    )

    if let minimum = descriptor.minimumVersion, let version, version < minimum {
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .outdated(found: version, required: minimum),
        installation: installation,
        detail: nil,
        at: now(),
        hints: hints
      )
    }

    let detail = version == nil ? "The reported version could not be parsed." : nil
    let authenticated = await authenticationState(
      specification: specification,
      probe: probe,
      environment: environment,
      path: path
    )
    guard authenticated != false else {
      return AgentDiagnosticFactory.availability(
        descriptor: descriptor,
        state: .unauthenticated,
        installation: installation,
        detail: detail,
        at: now(),
        hints: hints
      )
    }

    return AgentDiagnosticFactory.availability(
      descriptor: descriptor,
      state: .available,
      installation: installation,
      detail: detail,
      at: now(),
      hints: hints
    )
  }

  /// What one attempt at reading the version produced.
  ///
  /// Only `timedOut` is worth another attempt: an exit code, a refusal to start and a
  /// cancellation are all answers, and repeating them would only double the wait.
  private enum VersionProbeOutcome {
    case answered(ProbeResult)
    case timedOut
    case cancelled
    case notStarted
  }

  private static func versionProbeOutcome(
    specification: CommandLineAgentSpecification,
    probe: any ProcessProbe,
    environment: [String: String],
    path: String,
    timeout: Duration
  ) async -> VersionProbeOutcome {
    do {
      let result = try await probe.run(
        executablePath: path,
        arguments: specification.versionArguments,
        environment: AgentEnvironmentPolicy.environment(
          base: environment,
          additionalKeys: specification.additionalEnvironmentKeys
        ),
        workingDirectoryPath: nil,
        timeout: timeout
      )
      return result.didTimeOut ? .timedOut : .answered(result)
    } catch is CancellationError, ProbeError.cancelled {
      return .cancelled
    } catch {
      return .notStarted
    }
  }

  /// A located but unusable binary, so a failing diagnostic still says where it is.
  private static func located(
    path: String,
    source: AgentDetectionSource,
    now: @Sendable () -> Date
  ) -> AgentInstallation {
    AgentInstallation(executablePath: path, version: nil, source: source, detectedAt: now())
  }

  /// Best effort only: `nil` means "unknown", and unknown never blocks a launch.
  ///
  /// No token, credential file or keychain item is ever read; only the exit code of the
  /// command the provider declares is considered.
  private static func authenticationState(
    specification: CommandLineAgentSpecification,
    probe: any ProcessProbe,
    environment: [String: String],
    path: String
  ) async -> Bool? {
    guard let arguments = specification.authenticationArguments else { return nil }

    let result = try? await probe.run(
      executablePath: path,
      arguments: arguments,
      environment: AgentEnvironmentPolicy.environment(
        base: environment,
        additionalKeys: specification.additionalEnvironmentKeys
      ),
      workingDirectoryPath: nil,
      timeout: specification.versionTimeout
    )
    guard let result, !result.didTimeOut else { return nil }
    guard let outcome = specification.authenticationOutcome else { return result.exitCode == 0 }
    return outcome(result)
  }
}

/// What a remediation needs in order to be actionable rather than a bare label.
///
/// A provider declares them once in its specification: "install Codex" without a link and
/// "sign in" without the command to type are not remediations, they are restatements.
struct AgentRemediationHints: Sendable {
  var documentationURL: URL?
  var authenticationCommandLine: String?

  init(documentationURL: URL? = nil, authenticationCommandLine: String? = nil) {
    self.documentationURL = documentationURL
    self.authenticationCommandLine = authenticationCommandLine
  }

  init(specification: CommandLineAgentSpecification) {
    self.init(
      documentationURL: specification.documentationURL,
      authenticationCommandLine: specification.authenticationCommandLine
    )
  }
}

enum AgentDiagnosticFactory {
  static func availability(
    descriptor: AgentDescriptor,
    state: AgentAvailabilityState,
    installation: AgentInstallation?,
    detail: String?,
    at date: Date,
    hints: AgentRemediationHints = AgentRemediationHints()
  ) -> AgentAvailability {
    let diagnostic = AgentDiagnostic(
      providerID: descriptor.id,
      providerName: descriptor.displayName,
      state: state,
      summary: summary(for: state, descriptor: descriptor),
      detail: detail,
      installation: installation,
      probedAt: date,
      remediations: remediations(for: state, hints: hints)
    )
    return AgentAvailability(state: state, installation: installation, diagnostic: diagnostic)
  }

  private static func summary(
    for state: AgentAvailabilityState,
    descriptor: AgentDescriptor
  ) -> String {
    switch state {
    case .available:
      return "\(descriptor.displayName) is ready."
    case .outdated(let found, let required):
      return "\(descriptor.displayName) \(found) is older than the required \(required)."
    case .notFound:
      return "\(descriptor.displayName) was not found on this Mac."
    case .notExecutable:
      return "The \(descriptor.displayName) command exists but cannot be run."
    case .unauthenticated:
      return "\(descriptor.displayName) is installed but not signed in."
    case .probeFailed(let reason):
      // Saying "could not be inspected" about a command that simply stayed silent describes a
      // broken installation the user does not have.
      switch reason {
      case .timedOut:
        return "\(descriptor.displayName) did not answer in time."
      case .cancelled:
        return "The \(descriptor.displayName) check was interrupted."
      case .failed:
        return "\(descriptor.displayName) could not be inspected."
      }
    }
  }

  private static func remediations(
    for state: AgentAvailabilityState,
    hints: AgentRemediationHints
  ) -> [AgentRemediation] {
    switch state {
    case .available:
      return [.retryDetection]
    case .outdated(_, let required):
      return [
        .update(minimumVersion: required, documentationURL: hints.documentationURL),
        .retryDetection,
      ]
    case .notFound:
      return [
        .install(documentationURL: hints.documentationURL), .defineExecutablePath, .retryDetection,
      ]
    case .notExecutable:
      return [.defineExecutablePath, .retryDetection]
    case .unauthenticated:
      return [.authenticate(command: hints.authenticationCommandLine), .retryDetection]
    case .probeFailed(let reason):
      // Retrying explains nothing anywhere else, so it comes last. Here it is the explanation.
      return reason.isTransient
        ? [.retryDetection, .defineExecutablePath]
        : [.defineExecutablePath, .retryDetection]
    }
  }
}
