import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private struct SilentDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = []
  func signal(for event: AgentActivityEvent) -> AgentSignal? { nil }
}

/// A provider that can report, and — when `trust` is set — asks before its hooks run.
private final class ReportingProvider: AgentProvider, AgentActivityReporting, AgentHookTrusting,
  @unchecked Sendable
{
  let descriptor = AgentDescriptor(id: AgentProviderID("cli"), displayName: "Some CLI")
  private let lock = NSLock()
  private var trust: AgentHookTrust
  private(set) var trustChecks = 0
  private(set) var approvals = 0
  var approvalFails = false

  init(trust: AgentHookTrust) {
    self.trust = trust
  }

  func availability(forceRefresh: Bool) async -> AgentAvailability {
    fatalError("not used")
  }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    fatalError("not used")
  }

  func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: plan.providerID, executablePath: plan.executablePath,
      arguments: plan.arguments + ["-c", "hooks.Stop=x"],
      environment: plan.environment.merging(["LOG": log.path]) { $1 },
      workingDirectoryPath: plan.workingDirectoryPath, promptDelivery: plan.promptDelivery,
      version: plan.version)
  }

  func activityDecoder() -> any AgentSignalDecoding { SilentDecoder() }

  func hookTrust(for plan: AgentLaunchPlan) async -> AgentHookTrust {
    lock.withLock {
      trustChecks += 1
      return trust
    }
  }

  func trustHooks(of plan: AgentLaunchPlan) async throws {
    try lock.withLock {
      approvals += 1
      if approvalFails { throw CancellationError() }
      trust = .trusted
    }
  }
}

/// Reports, but never asks: Claude Code's case.
private struct OpenProvider: AgentProvider, AgentActivityReporting {
  let descriptor = AgentDescriptor(id: AgentProviderID("open"), displayName: "Open CLI")
  func availability(forceRefresh: Bool) async -> AgentAvailability { fatalError("not used") }
  func models() async -> [AgentModel] { [] }
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan {
    fatalError("not used")
  }
  func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    AgentLaunchPlan(
      providerID: plan.providerID, executablePath: plan.executablePath,
      arguments: plan.arguments + ["--settings", "{}"], environment: ["LOG": log.path],
      workingDirectoryPath: plan.workingDirectoryPath, promptDelivery: plan.promptDelivery)
  }
  func activityDecoder() -> any AgentSignalDecoding { SilentDecoder() }
}

private struct Registry: AgentProviderResolving {
  let providers: [any AgentProvider]
  func descriptors() async -> [AgentDescriptor] { providers.map(\.descriptor) }
  func provider(id: AgentProviderID) async -> (any AgentProvider)? {
    providers.first { $0.descriptor.id == id }
  }
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability] { [:] }
}

private actor NoLogs: AgentActivityLogStore {
  func prepareLog(for id: SessionID) -> URL { URL(fileURLWithPath: "/tmp/\(id).log") }
  func existingLog(for id: SessionID) -> URL? { nil }
  func events(for id: SessionID, from position: AgentActivityLogPosition?)
    -> AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
  { AsyncStream { $0.finish() } }
  func removeLog(for id: SessionID) {}
}

private actor NoStore: AgentActivityStateStore {
  func read() -> [SessionID: PersistedAgentActivity] { [:] }
  func write(_ activities: [SessionID: PersistedAgentActivity]) {}
}

private final class ConsentCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var asked: [[String]] = []
  let answer: AgentHookConsent

  init(answer: AgentHookConsent) {
    self.answer = answer
  }

  var requests: [[String]] { lock.withLock { asked } }

  func ask(_ name: String, _ commands: [String]) async -> AgentHookConsent {
    lock.withLock { asked.append(commands) }
    return answer
  }
}

private func plan(_ provider: String) -> AgentLaunchPlan {
  AgentLaunchPlan(
    providerID: AgentProviderID(provider), executablePath: "/bin/cli", arguments: ["-C", "/w"],
    environment: [:], workingDirectoryPath: "/w", promptDelivery: .none,
    version: AgentVersion(major: 1))
}

private func report(
  _ providers: [any AgentProvider], _ provider: String, consents: any AgentHookConsentStore,
  consent: ConsentCounter
) async -> ReportedLaunch {
  let tracker = TrackAgentActivity(logs: NoLogs(), store: NoStore())
  let use = ReportAgentActivity(
    agents: Registry(providers: providers), tracker: tracker, consents: consents)
  return await use(plan(provider), for: SessionID(), askConsent: consent.ask)
}

@Suite("Setting a launch up to report its activity")
struct ReportAgentActivityTests {
  @Test("A provider that cannot report launches as it was planned")
  func notReporting() async {
    let launch = await report(
      [], "absent", consents: InMemoryAgentHookConsentStore(),
      consent: ConsentCounter(answer: .approved))
    #expect(launch.plan == plan("absent"))
    #expect(launch.decoder == nil)
  }

  @Test("A provider that never asks gets its hooks without a question")
  func openProvider() async {
    let consent = ConsentCounter(answer: .declined)
    let launch = await report(
      [OpenProvider()], "open", consents: InMemoryAgentHookConsentStore(), consent: consent)
    #expect(launch.plan.arguments == ["-C", "/w", "--settings", "{}"])
    #expect(launch.decoder != nil)
    #expect(consent.requests.isEmpty)
  }

  @Test("Hooks the CLI trusts are remembered, and not asked about again")
  func trustedIsRemembered() async {
    let provider = ReportingProvider(trust: .trusted)
    let consents = InMemoryAgentHookConsentStore()
    let consent = ConsentCounter(answer: .declined)
    _ = await report([provider], "cli", consents: consents, consent: consent)
    _ = await report([provider], "cli", consents: consents, consent: consent)
    #expect(provider.trustChecks == 1)
    #expect(consent.requests.isEmpty)
  }

  @Test("A yes approves the hooks through the CLI, once")
  func yesApproves() async {
    let provider = ReportingProvider(trust: .needsApproval(commands: ["hook"]))
    let consents = InMemoryAgentHookConsentStore()
    let consent = ConsentCounter(answer: .approved)
    let launch = await report([provider], "cli", consents: consents, consent: consent)
    #expect(consent.requests == [["hook"]])
    #expect(provider.approvals == 1)
    #expect(launch.decoder != nil)
    #expect(launch.plan.arguments.contains("hooks.Stop=x"))
    _ = await report([provider], "cli", consents: consents, consent: consent)
    #expect(consent.requests.count == 1)
  }

  @Test("A no launches without hooks, and is not asked again until the setting changes")
  func noDeclines() async {
    let provider = ReportingProvider(trust: .needsApproval(commands: ["hook"]))
    let consents = InMemoryAgentHookConsentStore()
    let consent = ConsentCounter(answer: .declined)
    let launch = await report([provider], "cli", consents: consents, consent: consent)
    #expect(launch.plan == plan("cli"))
    #expect(launch.decoder == nil)
    #expect(consents.isDeclined(AgentProviderID("cli")))
    _ = await report([provider], "cli", consents: consents, consent: consent)
    #expect(consent.requests.count == 1)
    #expect(provider.trustChecks == 1)
  }

  @Test("An approval that fails, or a CLI that cannot be asked, leaves it to the CLI to ask")
  func failuresLaunchWithHooks() async {
    let failing = ReportingProvider(trust: .needsApproval(commands: ["hook"]))
    failing.approvalFails = true
    let consents = InMemoryAgentHookConsentStore()
    let launch = await report(
      [failing], "cli", consents: consents, consent: ConsentCounter(answer: .approved))
    #expect(launch.decoder != nil)
    #expect(consents.approvedFingerprint(for: AgentProviderID("cli")) == nil)

    let unknown = ReportingProvider(trust: .unknown)
    let second = await report(
      [unknown], "cli", consents: InMemoryAgentHookConsentStore(),
      consent: ConsentCounter(answer: .approved))
    #expect(second.decoder != nil)
  }

  @Test("The fingerprint follows the CLI, its version and its hooks, not the session")
  func fingerprint() {
    let base = plan("cli")
    let hooked = AgentLaunchPlan(
      providerID: base.providerID, executablePath: base.executablePath,
      arguments: ["-c", "hooks.Stop=x", "-m", "a"], environment: [:],
      workingDirectoryPath: "/a", promptDelivery: .none, version: base.version)
    let otherSession = AgentLaunchPlan(
      providerID: base.providerID, executablePath: base.executablePath,
      arguments: ["-m", "b", "-c", "hooks.Stop=x", "--", "prompt"], environment: ["X": "1"],
      workingDirectoryPath: "/b", promptDelivery: .argument, version: base.version)
    let newer = AgentLaunchPlan(
      providerID: base.providerID, executablePath: base.executablePath,
      arguments: ["-c", "hooks.Stop=x"], environment: [:], workingDirectoryPath: "/a",
      promptDelivery: .none, version: AgentVersion(major: 2))
    #expect(
      ReportAgentActivity.fingerprint(of: hooked)
        == ReportAgentActivity.fingerprint(of: otherSession))
    #expect(
      ReportAgentActivity.fingerprint(of: hooked) != ReportAgentActivity.fingerprint(of: newer))
    #expect(
      ReportAgentActivity.fingerprint(of: hooked) != ReportAgentActivity.fingerprint(of: base))
  }

  @Test("No answer launches without hooks, remembers nothing, and asks again next time")
  func undecided() async {
    let provider = ReportingProvider(trust: .needsApproval(commands: ["hook"]))
    let consents = InMemoryAgentHookConsentStore()
    let consent = ConsentCounter(answer: .undecided)
    let launch = await report([provider], "cli", consents: consents, consent: consent)
    #expect(launch.decoder == nil)
    #expect(!consents.isDeclined(AgentProviderID("cli")))
    _ = await report([provider], "cli", consents: consents, consent: consent)
    #expect(consent.requests.count == 2)
  }

  @Test("A yes lifts a no given before")
  func yesLiftsNo() async {
    let provider = ReportingProvider(trust: .needsApproval(commands: ["hook"]))
    let consents = InMemoryAgentHookConsentStore()
    consents.setDeclined(true, for: AgentProviderID("other"))
    // Declined, then turned back on in the settings: the next launch asks, and the yes stays.
    consents.setDeclined(false, for: AgentProviderID("cli"))
    _ = await report(
      [provider], "cli", consents: consents, consent: ConsentCounter(answer: .approved))
    #expect(!consents.isDeclined(AgentProviderID("cli")))
  }

  @Test("A CLI that cannot be asked is asked once per run")
  func unknownIsRemembered() async {
    let provider = ReportingProvider(trust: .unknown)
    let tracker = TrackAgentActivity(logs: NoLogs(), store: NoStore())
    let use = ReportAgentActivity(
      agents: Registry(providers: [provider]), tracker: tracker,
      consents: InMemoryAgentHookConsentStore())
    let consent = ConsentCounter(answer: .approved)
    _ = await use(plan("cli"), for: SessionID(), askConsent: consent.ask)
    let second = await use(plan("cli"), for: SessionID(), askConsent: consent.ask)
    #expect(provider.trustChecks == 1)
    #expect(second.decoder != nil)
  }
}
