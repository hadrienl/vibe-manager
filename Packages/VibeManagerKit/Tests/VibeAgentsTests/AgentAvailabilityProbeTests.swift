import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

@Suite("Agent availability detection")
struct AgentAvailabilityProbeTests {
  private func probe(
    locator: any ExecutableLocator,
    processProbe: any ProcessProbe,
    descriptor: AgentDescriptor = TestFixtures.descriptor,
    timeToLive: Duration = .seconds(300)
  ) -> AgentAvailabilityProbe {
    AgentAvailabilityProbe(
      descriptor: descriptor,
      specification: TestFixtures.specification,
      locator: locator,
      probe: processProbe,
      environment: ["PATH": "/usr/bin", "HOME": "/Users/test"],
      timeToLive: timeToLive,
      now: { Date(timeIntervalSince1970: 0) }
    )
  }

  @Test("A recent enough CLI is available with its path, source and version")
  func reportsAvailableInstallation() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    ).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.executablePath == "/opt/homebrew/bin/stub-agent")
    #expect(availability.installation?.source == .candidateDirectory)
    #expect(availability.installation?.version == AgentVersion(major: 2, minor: 4, patch: 1))
    #expect(availability.isUsable)
  }

  @Test("A version below the minimum is outdated, not missing")
  func reportsOutdatedVersion() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 1.9.9"))
      )
    ).availability(forceRefresh: false)

    #expect(
      availability.state
        == .outdated(
          found: AgentVersion(major: 1, minor: 9, patch: 9),
          required: AgentVersion(major: 2, minor: 0, patch: 0)
        )
    )
    #expect(!availability.isUsable)
    #expect(
      availability.diagnostic.remediations.contains(
        .update(minimumVersion: AgentVersion(major: 2, minor: 0, patch: 0), documentationURL: nil)
      )
    )
  }

  @Test("An unreadable version does not disable the agent")
  func unparsableVersionStaysAvailable() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "nightly build"))
      )
    ).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == nil)
    #expect(availability.diagnostic.detail != nil)
  }

  @Test("A version probe that times out is reported without throwing")
  func reportsTimeout() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))
      )
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .timedOut))
    #expect(!availability.isUsable)
  }

  @Test("A non zero exit code from the version probe is a probe failure")
  func reportsFailingVersionProbe() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 127, standardError: "not found"))
      )
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .failed(exitCode: 127)))
  }

  @Test("A binary that cannot be started is reported, not crashed on")
  func reportsLaunchFailure() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(defaultResponse: .failure(.launchFailed))
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .failed(exitCode: -1)))
  }

  @Test("A missing CLI offers install, manual path and retry")
  func missingCLIOffersRemediations() async {
    let availability = await probe(
      locator: StubLocator(location: .notFound),
      processProbe: StubProcessProbe()
    ).availability(forceRefresh: false)

    #expect(availability.state == .notFound)
    #expect(availability.installation == nil)
    #expect(availability.diagnostic.remediations.contains(.defineExecutablePath))
    #expect(availability.diagnostic.remediations.contains(.retryDetection))
  }

  @Test("A non executable file is distinguished from a missing one")
  func reportsNonExecutable() async {
    let availability = await probe(
      locator: StubLocator(
        location: .notExecutable(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
      ),
      processProbe: StubProcessProbe()
    ).availability(forceRefresh: false)

    #expect(availability.state == .notExecutable)
    #expect(availability.installation?.executablePath == "/opt/homebrew/bin/stub-agent")
  }

  @Test("A failing authentication command downgrades to unauthenticated without blocking")
  func detectsUnauthenticated() async {
    let specification = CommandLineAgentSpecification(
      binaryName: "stub-agent",
      authenticationArguments: ["auth", "status"]
    )
    let processProbe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
    )
    let authenticationProbe = StubAuthenticationProbe(
      versionOutput: "stub-agent 2.4.1",
      authenticationExitCode: 1
    )

    let availability = await AgentAvailabilityProbe(
      descriptor: TestFixtures.descriptor,
      specification: specification,
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      probe: authenticationProbe,
      environment: [:],
      now: { Date(timeIntervalSince1970: 0) }
    ).availability(forceRefresh: false)

    #expect(availability.state == .unauthenticated)
    // Not being able to prove a sign in must never prevent launching the agent.
    #expect(availability.isUsable)
    #expect(processProbe.invocations.isEmpty)
  }

  @Test("Concurrent callers share a single detection and the cache avoids further probes")
  func cachesAndCoalesces() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath),
      delay: .milliseconds(20)
    )
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    async let first = subject.availability(forceRefresh: false)
    async let second = subject.availability(forceRefresh: false)
    _ = await (first, second)
    _ = await subject.availability(forceRefresh: false)

    #expect(locator.invocationCount == 1)

    await subject.invalidate()
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 2)
  }

  @Test("Forcing a refresh always probes again")
  func forceRefreshBypassesCache() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
    )
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    _ = await subject.availability(forceRefresh: false)
    _ = await subject.availability(forceRefresh: true)

    #expect(locator.invocationCount == 2)
  }

  @Test("A detection started before an invalidation never repopulates the cache")
  func staleDetectionDoesNotRepopulateCache() async {
    let locator = CountingLocator(
      location: .found(path: "/old/stub-agent", source: .processPath),
      delay: .milliseconds(100)
    )
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    async let inFlight = subject.availability(forceRefresh: false)
    try? await Task.sleep(for: .milliseconds(20))
    await subject.setUserDefinedPath("/custom/stub-agent")
    _ = await inFlight

    // The stale result must not be served from the cache afterwards.
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 2)
  }

  @Test("A sub second time to live still caches")
  func subSecondTimeToLiveIsHonoured() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
    )
    let clock = MutableClock(start: Date(timeIntervalSince1970: 0))
    let subject = AgentAvailabilityProbe(
      descriptor: TestFixtures.descriptor,
      specification: TestFixtures.specification,
      locator: locator,
      probe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      ),
      environment: [:],
      timeToLive: .milliseconds(500),
      now: { clock.now }
    )

    _ = await subject.availability(forceRefresh: false)
    clock.advance(by: 0.2)
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 1)

    clock.advance(by: 0.4)
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 2)
  }

  @Test("A cancelled probe is reported as cancelled, not as a launch failure")
  func reportsCancellation() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(defaultResponse: .failure(.cancelled))
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .cancelled))
  }

  @Test("A failing probe still reports where the executable was found")
  func failingProbeKeepsThePath() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))
      )
    ).availability(forceRefresh: false)

    #expect(availability.installation?.executablePath == "/opt/homebrew/bin/stub-agent")
    #expect(availability.installation?.source == .candidateDirectory)
  }

  @Test("A warning printed before the version does not change the detected version")
  func ignoresUnrelatedNumbersInOutput() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(
          ProbeResult(
            exitCode: 0,
            standardOutput: "warning: requires Node 18.0.0\nstub-agent 2.4.1"
          )
        )
      )
    ).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == AgentVersion(major: 2, minor: 4, patch: 1))
  }

  @Test("Setting a user defined path invalidates the cached detection")
  func userPathInvalidatesCache() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .userDefined)
    )
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    _ = await subject.availability(forceRefresh: false)
    await subject.setUserDefinedPath("/custom/stub-agent")
    _ = await subject.availability(forceRefresh: false)

    #expect(locator.invocationCount == 2)
  }

  @Test("A forced refresh is not overwritten by the slower detection it supersedes")
  func forcedRefreshSupersedesTheDetectionInFlight() async throws {
    let locator = ScriptedLocator(responses: [
      (.notFound, .milliseconds(300)),
      (.found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory), .zero),
    ])
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    async let pending = subject.availability(forceRefresh: false)
    try await Task.sleep(for: .milliseconds(50))
    let refreshed = await subject.availability(forceRefresh: true)
    _ = await pending

    #expect(refreshed.state == .available)
    // The slow detection landed last; it must not have repopulated the cache with its result.
    #expect(await subject.availability(forceRefresh: false).state == .available)
  }

  @Test("A caller waiting on an invalidated detection is re-probed, not handed its cancellation")
  func waiterIsReprobedAfterAnInvalidation() async throws {
    let locator = ScriptedLocator(responses: [
      (.notFound, .milliseconds(300)),
      (.found(path: "/custom/bin/stub-agent", source: .userDefined), .zero),
    ])
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      )
    )

    async let owner = subject.availability(forceRefresh: false)
    try await Task.sleep(for: .milliseconds(50))
    async let waiter = subject.availability(forceRefresh: false)
    try await Task.sleep(for: .milliseconds(50))
    await subject.setUserDefinedPath("/custom/bin/stub-agent")

    let results = await [owner, waiter]
    #expect(results.allSatisfy { $0.state == .available })
  }
}

/// Answers the version probe and the authentication probe differently.
private struct StubAuthenticationProbe: ProcessProbe {
  let versionOutput: String
  let authenticationExitCode: Int32

  func run(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectoryPath: String?,
    timeout: Duration
  ) async throws -> ProbeResult {
    guard arguments == ["--version"] else {
      return ProbeResult(exitCode: authenticationExitCode)
    }
    return ProbeResult(exitCode: 0, standardOutput: versionOutput)
  }

}
