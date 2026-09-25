import Foundation
import Testing
import VibeApplication
import VibeDomain

private let developmentLeaf =
  "certificate leaf[subject.CN] = \"Apple Development: A (5R795X4XPD)\""

@Suite("Asking for file access once")
struct FullDiskAccessGateTests {
  private let developer = CodeIdentityFingerprint(
    identifier: "eu.hadrien.VibeManager", team: "QMJKZ67Z3H",
    designatedRequirement: developmentLeaf)

  @Test("With the access granted, there is nothing to ask")
  func grantedAsksNothing() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .granted),
      preferences: SpyPreferences()
    )

    #expect(await gate.status() == .granted)
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Without it, and never asked, the step is presented")
  func notGrantedAsksOnce() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences()
    )

    #expect(await gate.shouldPresentStep())
  }

  @Test("A refusal is an answer: the same identity is not asked again")
  func refusalIsNotAskedAgain() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences(answeredBy: developer),
      identity: FixedIdentity(developer)
    )

    #expect(await gate.shouldPresentStep() == false)
  }

  @Test(
    "Another code identity is another application to TCC: the step comes back, once",
    arguments: [
      CodeIdentityFingerprint(
        identifier: "com.hadrienl.VibeManager", team: "QMJKZ67Z3H",
        designatedRequirement: developmentLeaf),
      CodeIdentityFingerprint(
        identifier: "eu.hadrien.VibeManager", team: "OTHERTEAM1",
        designatedRequirement: developmentLeaf),
      CodeIdentityFingerprint(
        identifier: "eu.hadrien.VibeManager", team: "QMJKZ67Z3H",
        designatedRequirement: "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"),
    ])
  func newIdentityAsksAgainOnce(previous: CodeIdentityFingerprint) async {
    // The bundle identifier, the team, or the move from Apple Development to Developer ID: TCC
    // keeps the grant against the old identity, and the new one has nothing.
    let preferences = SpyPreferences(answeredBy: previous)
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted), preferences: preferences,
      identity: FixedIdentity(developer))

    #expect(await gate.shouldPresentStep())
    await gate.dismissStep()

    let nextLaunch = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted), preferences: preferences,
      identity: FixedIdentity(developer))
    #expect(await nextLaunch.shouldPresentStep() == false)
    #expect(await preferences.answer == developer)
  }

  @Test("An ad-hoc build keeps its answer from one compilation to the next")
  func adHocIsStableAcrossBuilds() async {
    // Its designated requirement is its own hash; keying on it would ask at every build.
    let preferences = SpyPreferences(answeredBy: .adHoc(identifier: "eu.hadrien.VibeManager"))
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted), preferences: preferences,
      identity: FixedIdentity(.adHoc(identifier: "eu.hadrien.VibeManager")))

    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Answering the step records it, once")
  func dismissingIsRecorded() async {
    let preferences = SpyPreferences()
    let gate = FullDiskAccessGate(probe: StubProbe(status: .notGranted), preferences: preferences)

    #expect(await gate.shouldPresentStep())
    await gate.dismissStep()

    #expect(await preferences.dismissals == 1)
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("This process is probed once: its answer cannot change while it runs")
  func statusIsProbedOnce() async {
    // TCC settles the access for the process responsible when it starts (#76).
    let probe = StubProbe(status: .notGranted)
    let gate = FullDiskAccessGate(probe: probe, preferences: SpyPreferences())

    _ = await gate.status()
    _ = await gate.shouldPresentStep()
    _ = await gate.report(refreshingIdentity: true)

    #expect(await probe.probes == 1)
  }

  @Test("A process born now tells what this one cannot: that the switch was turned on since")
  func currentProbeSeesAGrantThisProcessCannot() async {
    let current = StubCurrentProbe(status: .notGranted)
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted), preferences: SpyPreferences(), current: current)

    #expect(await gate.report(refreshingIdentity: true).situation == .notGranted)
    await current.set(.granted)

    let report = await gate.report(refreshingIdentity: true)
    #expect(report.identity == .granted)
    #expect(report.interface == .notGranted)
    #expect(report.situation == .granted)
  }

  @Test("A process born now that never answers changes nothing")
  func silentCurrentProbeKeepsTheLaunchAnswer() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .granted), preferences: SpyPreferences(),
      current: StubCurrentProbe(status: nil))

    #expect(await gate.identityStatus(refreshing: true) == .granted)
  }

  @Test("The step is offered once per launch, whoever asks")
  func stepIsOfferedOncePerLaunch() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted),
      preferences: SpyPreferences()
    )

    #expect(await gate.shouldPresentStep())
    #expect(await gate.shouldPresentStep() == false)
  }

  @Test("Two callers asking at the same time still get one step")
  func concurrentCallersAreOfferedOneStep() async {
    let gate = FullDiskAccessGate(
      probe: SlowProbe(status: .notGranted),
      preferences: SlowPreferences()
    )

    async let first = gate.shouldPresentStep()
    async let second = gate.shouldPresentStep()
    let answers = await [first, second]

    #expect(answers.filter { $0 }.count == 1)
  }

  @Test("A step withheld because access was granted is not owed forever")
  func aStepNotPresentedIsNotSpent() async {
    // Nothing was shown, so nothing was answered: if the access is taken away later in the same
    // launch, the step is still the gate's to offer.
    let current = StubCurrentProbe(status: .granted)
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .granted), preferences: SpyPreferences(), current: current)

    #expect(await gate.shouldPresentStep() == false)
    await current.set(.notGranted)
    _ = await gate.identityStatus(refreshing: true)

    #expect(await gate.shouldPresentStep())
  }

  @Test("The report asks the process that runs the agents")
  func reportIncludesTheRunner() async {
    let runner = StubRunner(
      access: AgentRunnerAccess(runner: .host, hostStatus: .notGranted, runningAgents: 2))
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .granted), preferences: SpyPreferences(), runner: runner)

    let report = await gate.report(refreshingIdentity: false)

    #expect(report.situation == .pendingRestart(runner: .host, runningAgents: 2))
    #expect(!report.isConsistent)
  }
}

private typealias SituationCase = (
  FullDiskAccessStatus?, FullDiskAccessStatus?, AgentRunnerAccess, FullDiskAccessSituation
)

@Suite("Where the access granted stands")
struct FullDiskAccessSituationTests {
  @Test(
    "Identity × runner, line by line",
    arguments: [
      (nil, nil, AgentRunnerAccess.none, FullDiskAccessSituation.checking),
      (.notGranted, .notGranted, .none, .notGranted),
      (.notGranted, .granted, .none, .notGranted),
      (.granted, .notGranted, .none, .granted),
      (.granted, .notGranted, AgentRunnerAccess(runner: .host, hostStatus: .granted), .granted),
      (
        .granted, .granted,
        AgentRunnerAccess(runner: .host, hostStatus: .notGranted, runningAgents: 3),
        .pendingRestart(runner: .host, runningAgents: 3)
      ),
      // A host left by an earlier build cannot say: it is not taken at its word.
      (
        .granted, .granted, AgentRunnerAccess(runner: .host, hostStatus: nil, runningAgents: 1),
        .pendingRestart(runner: .host, runningAgents: 1)
      ),
      (.granted, .granted, AgentRunnerAccess(runner: .application, runningAgents: 1), .granted),
      (
        .granted, .notGranted, AgentRunnerAccess(runner: .application, runningAgents: 1),
        .pendingRestart(runner: .application, runningAgents: 1)
      ),
      // Without a process born now, this one's answer at launch was the identity's then.
      (nil, .granted, .none, .granted),
      (nil, .notGranted, .none, .notGranted),
    ] as [SituationCase]
  )
  func resolves(
    identity: FullDiskAccessStatus?, interface: FullDiskAccessStatus?,
    runner: AgentRunnerAccess, expected: FullDiskAccessSituation
  ) {
    #expect(
      FullDiskAccessSituation.resolve(identity: identity, interface: interface, runner: runner)
        == expected)
  }
}

@Suite("Restarting the host so the agents get the access")
struct RestartAgentHostTests {
  private func session(_ name: String, updatedAt seconds: TimeInterval) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: "",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "kept"),
      status: .active,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: seconds),
      repositories: [RepositoryContext(path: "/tmp")]
    )
  }

  @Test("Only the agents running in the host are stopped, then resumed, most recent first")
  func stopsTheHostedAgentsAndResumesThem() async {
    let recent = session("Recent", updatedAt: 1_700_000_200)
    let older = session("Older", updatedAt: 1_700_000_100)
    let elsewhere = session("Elsewhere", updatedAt: 1_700_000_300)
    let repository = RestorationRepository(sessions: [recent, older, elsewhere])
    let runtime = DetachingRuntime()
    let runner = StubRunner(
      access: AgentRunnerAccess(runner: .host, hostStatus: .notGranted, runningAgents: 2),
      running: [older.id, recent.id])
    let subject = RestartAgentHost(
      repository: repository, runtime: runtime,
      recorder: SessionRuntimeRecorder(store: EphemeralSessionRuntimeStateStore()),
      control: runner)

    let intent = await subject(await subject.sessions())

    #expect(intent.sessionIDs == [recent.id, older.id])
    #expect(Set(await runtime.detached) == [recent.id, older.id])
    #expect(await repository.status(of: elsewhere.id) == .active)
    #expect(await runner.restartRequests == 1)
  }
}

private struct FixedIdentity: CodeIdentityReading {
  let fingerprint: CodeIdentityFingerprint

  init(_ fingerprint: CodeIdentityFingerprint) {
    self.fingerprint = fingerprint
  }

  func current() -> CodeIdentityFingerprint { fingerprint }
}

/// Suspends before answering, so that a second caller really does run in the gap.
private actor SlowProbe: FullDiskAccessProbe {
  private let value: FullDiskAccessStatus

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func status() async -> FullDiskAccessStatus {
    await Task.yield()
    return value
  }
}

private actor SlowPreferences: PermissionPreferences {
  func isFullDiskAccessStepSuppressed() -> Bool { false }

  private var answer: CodeIdentityFingerprint?

  func fullDiskAccessStepAnswer() async -> CodeIdentityFingerprint? {
    await Task.yield()
    return answer
  }

  func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) { answer = identity }
}

private actor StubProbe: FullDiskAccessProbe {
  private let value: FullDiskAccessStatus
  private(set) var probes = 0

  init(status: FullDiskAccessStatus) {
    value = status
  }

  func status() async -> FullDiskAccessStatus {
    probes += 1
    return value
  }
}

private actor StubCurrentProbe: CurrentFullDiskAccessProbe {
  private var value: FullDiskAccessStatus?

  init(status: FullDiskAccessStatus?) {
    value = status
  }

  func set(_ status: FullDiskAccessStatus?) { value = status }

  func status() async -> FullDiskAccessStatus? { value }
}

private actor SpyPreferences: PermissionPreferences {
  func isFullDiskAccessStepSuppressed() -> Bool { false }

  private(set) var answer: CodeIdentityFingerprint?
  private(set) var dismissals = 0

  init(answeredBy answer: CodeIdentityFingerprint? = nil) {
    self.answer = answer
  }

  func fullDiskAccessStepAnswer() -> CodeIdentityFingerprint? { answer }

  func recordFullDiskAccessStepAnswer(by identity: CodeIdentityFingerprint) {
    dismissals += 1
    answer = identity
  }
}

private actor StubRunner: AgentRunnerControl {
  private let access: AgentRunnerAccess
  private let running: [SessionID]
  private(set) var restartRequests = 0

  init(access: AgentRunnerAccess, running: [SessionID] = []) {
    self.access = access
    self.running = running
  }

  func agentRunnerAccess() -> AgentRunnerAccess { access }

  func runningHostedSessions() -> [SessionID] { running }

  func restartHostWhenIdle() -> HostRestart {
    restartRequests += 1
    return .restarted
  }

  func cancelHostRestart() {
    // Nothing is armed here.
  }

  func isHostRestartArmed() -> Bool { false }
}

private actor DetachingRuntime: SessionRuntime {
  private(set) var detached: [SessionID] = []

  func detach(_ id: SessionID) async -> SessionDetachOutcome {
    detached.append(id)
    return .stopped
  }

  func dispose(_: SessionID) async {
    // Nothing is held here, so there is nothing to release.
  }
}

@Suite("A step suppressed from outside")
struct SuppressedStepTests {
  @Test("Suppressed, the step is not shown to any identity")
  func suppressedStepIsNeverShown() async {
    let gate = FullDiskAccessGate(
      probe: StubProbe(status: .notGranted), preferences: SuppressingPreferences())

    #expect(await gate.shouldPresentStep() == false)
  }
}

private actor SuppressingPreferences: PermissionPreferences {
  func fullDiskAccessStepAnswer() -> CodeIdentityFingerprint? { nil }

  func recordFullDiskAccessStepAnswer(by _: CodeIdentityFingerprint) {
    // Never answered: the step is suppressed.
  }

  func isFullDiskAccessStepSuppressed() -> Bool { true }
}
