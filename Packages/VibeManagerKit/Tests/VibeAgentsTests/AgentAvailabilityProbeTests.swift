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
    timeToLive: Duration = .seconds(20),
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
  ) -> AgentAvailabilityProbe {
    AgentAvailabilityProbe(
      descriptor: descriptor,
      specification: TestFixtures.specification,
      locator: locator,
      probe: processProbe,
      environment: ["PATH": "/usr/bin", "HOME": "/Users/test"],
      timeToLive: timeToLive,
      now: now
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

  @Test("Only a second silence in a row is a timeout")
  func reportsTimeoutAfterTwoAttempts() async {
    let processProbe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))
    )
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: processProbe
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .timedOut))
    #expect(!availability.isUsable)
    let versionProbes = processProbe.invocations.filter { $0.arguments == ["--version"] }
    #expect(versionProbes.count == 2)
    // The second attempt is the one that has to conclude, so it gets the wider budget.
    #expect(versionProbes.last?.timeout == TestFixtures.specification.versionRetryTimeout)
    #expect(versionProbes.first?.timeout == TestFixtures.specification.versionTimeout)
  }

  @Test("A CLI that answers on the retry is available, not broken")
  func retriesOnceAfterATimeout() async {
    let processProbe = ScriptedProcessProbe(responses: [
      .success(ProbeResult(exitCode: -1, didTimeOut: true)),
      .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1")),
    ])
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .candidateDirectory)
      ),
      processProbe: processProbe
    ).availability(forceRefresh: false)

    #expect(availability.state == .available)
    #expect(availability.installation?.version == AgentVersion(major: 2, minor: 4, patch: 1))
    #expect(processProbe.invocations.count == 2)
  }

  @Test("A timeout says the agent stayed silent, and offers to detect again first")
  func timeoutReadsAsTransient() async {
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))
      )
    ).availability(forceRefresh: false)

    #expect(availability.diagnostic.summary == "Stub Agent did not answer in time.")
    #expect(availability.diagnostic.remediations.first == .retryDetection)
  }

  @Test("A non zero exit code from the version probe is a probe failure, and is not retried")
  func reportsFailingVersionProbe() async {
    let processProbe = StubProcessProbe(
      defaultResponse: .success(ProbeResult(exitCode: 127, standardError: "not found"))
    )
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: processProbe
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .failed(exitCode: 127)))
    // An exit code is an answer: asking again would only double the wait for the same verdict.
    #expect(processProbe.invocations.count == 1)
    #expect(availability.diagnostic.summary == "Stub Agent could not be inspected.")
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

  @Test("A login shell that never answered is not a missing agent")
  func aSilentLoginShellIsNotAMissingAgent() async {
    let availability = await probe(
      locator: StubLocator(location: .timedOut),
      processProbe: StubProcessProbe()
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .timedOut))
    #expect(availability.diagnostic.remediations.first == .retryDetection)
    // Being told to install a CLI that is already there is the verdict this avoids.
    #expect(!availability.diagnostic.remediations.contains(.install(documentationURL: nil)))
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
    let locator = CountingLocator(location: .notFound)
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

  @Test("A cancelled probe is reported as cancelled, not as a launch failure, and is not retried")
  func reportsCancellation() async {
    let processProbe = StubProcessProbe(defaultResponse: .failure(.cancelled))
    let availability = await probe(
      locator: StubLocator(
        location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
      ),
      processProbe: processProbe
    ).availability(forceRefresh: false)

    #expect(availability.state == .probeFailed(reason: .cancelled))
    #expect(processProbe.invocations.count == 1)
  }

  @Test("A silent agent is detected again on the next screen")
  func aTransientFailureExpires() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
    )
    let clock = MutableClock(start: Date(timeIntervalSince1970: 0))
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: -1, didTimeOut: true))
      ),
      now: { clock.now }
    )

    _ = await subject.availability(forceRefresh: false)
    clock.advance(by: 10)
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 1)

    // The next screen the user opens detects again by itself, instead of repeating a verdict
    // nobody trusts.
    clock.advance(by: 15)
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 2)
  }

  @Test("An agent whose remediation the user may be performing is detected again")
  func anUnauthenticatedAgentExpires() async {
    let specification = CommandLineAgentSpecification(
      binaryName: "stub-agent",
      authenticationArguments: ["auth", "status"]
    )
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
    )
    let clock = MutableClock(start: Date(timeIntervalSince1970: 0))
    let subject = AgentAvailabilityProbe(
      descriptor: TestFixtures.descriptor,
      specification: specification,
      locator: locator,
      probe: StubAuthenticationProbe(versionOutput: "stub-agent 2.4.1", authenticationExitCode: 1),
      environment: [:],
      timeToLive: .seconds(20),
      now: { clock.now }
    )

    #expect(await subject.availability(forceRefresh: false).state == .unauthenticated)
    // Signing in happens in a terminal, next to the application: coming back to the sheet has to
    // be enough to see it, without the user having to find the detect button first.
    clock.advance(by: 25)
    _ = await subject.availability(forceRefresh: false)

    #expect(locator.invocationCount == 2)
  }

  @Test("A ready agent is detected once, and not again for the rest of the session")
  func aReadyAgentIsProbedOnce() async {
    let locator = CountingLocator(
      location: .found(path: "/opt/homebrew/bin/stub-agent", source: .processPath)
    )
    let clock = MutableClock(start: Date(timeIntervalSince1970: 0))
    let subject = probe(
      locator: locator,
      processProbe: StubProcessProbe(
        defaultResponse: .success(ProbeResult(exitCode: 0, standardOutput: "stub-agent 2.4.1"))
      ),
      now: { clock.now }
    )

    _ = await subject.availability(forceRefresh: false)
    // A CLI does not uninstall itself while the application runs; opening the sheet an hour
    // later must not cost a process.
    clock.advance(by: 3600)
    _ = await subject.availability(forceRefresh: false)
    #expect(locator.invocationCount == 1)

    // Only an explicit detection, or a new user defined path, looks again.
    _ = await subject.availability(forceRefresh: true)
    #expect(locator.invocationCount == 2)
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
