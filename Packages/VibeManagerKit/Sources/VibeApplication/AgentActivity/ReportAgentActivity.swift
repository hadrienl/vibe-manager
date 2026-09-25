import CryptoKit
import Foundation
import VibeDomain

/// What the user decided about the hooks of a CLI that asks before running them, kept across
/// launches.
public protocol AgentHookConsentStore: Sendable {
  /// The hooks the user last saw approved, by fingerprint. The same fingerprint again means the
  /// CLI needs not be asked.
  func approvedFingerprint(for provider: AgentProviderID) -> String?
  func setApprovedFingerprint(_ fingerprint: String?, for provider: AgentProviderID)
  /// The user said no: this CLI's agents run without hooks until the setting is turned back on.
  func isDeclined(_ provider: AgentProviderID) -> Bool
  func setDeclined(_ declined: Bool, for provider: AgentProviderID)
}

/// Kept for this run only. What a workspace assembled without the system around it uses.
public final class InMemoryAgentHookConsentStore: AgentHookConsentStore, @unchecked Sendable {
  private let lock = NSLock()
  private var fingerprints: [AgentProviderID: String] = [:]
  private var declined: Set<AgentProviderID> = []

  public init() {}

  public func approvedFingerprint(for provider: AgentProviderID) -> String? {
    lock.withLock { fingerprints[provider] }
  }

  public func setApprovedFingerprint(_ fingerprint: String?, for provider: AgentProviderID) {
    lock.withLock { fingerprints[provider] = fingerprint }
  }

  public func isDeclined(_ provider: AgentProviderID) -> Bool {
    lock.withLock { declined.contains(provider) }
  }

  public func setDeclined(_ value: Bool, for provider: AgentProviderID) {
    lock.withLock {
      if value { declined.insert(provider) } else { declined.remove(provider) }
    }
  }
}

/// What the user answered when asked to let a CLI's hooks be approved.
public enum AgentHookConsent: Hashable, Sendable {
  case approved
  /// "Not Now": remembered, until the setting is turned back on.
  case declined
  /// No answer — the sheet was closed, the application quit: this launch goes without hooks, and
  /// the next one asks again.
  case undecided
}

/// Asked of the user before a CLI's hooks are approved on their behalf: the agent's name, and the
/// commands its hooks run.
public typealias AgentHookConsentRequest =
  @Sendable (_ agentName: String, _ commands: [String])
  async -> AgentHookConsent

/// A launch plan, set up to report its agent's activity when its provider can (#45).
public struct ReportedLaunch: Sendable {
  public let plan: AgentLaunchPlan
  /// `nil` when the agent reports nothing: its activity is then read from its output.
  public let decoder: (any AgentSignalDecoding)?

  public init(plan: AgentLaunchPlan, decoder: (any AgentSignalDecoding)?) {
    self.plan = plan
    self.decoder = decoder
  }
}

/// Sets a launch up to report what its agent does, and settles the approval of its hooks when its
/// CLI asks for one.
///
/// Never in the way of the launch: a log that cannot be prepared, a CLI that cannot be asked, an
/// approval that does not take — the agent starts all the same, only with less to say about it.
public struct ReportAgentActivity: Sendable {
  private let agents: any AgentProviderResolving
  private let tracker: TrackAgentActivity
  private let consents: any AgentHookConsentStore
  private let diagnostics: Diagnostics
  /// The fingerprints Codex could not be asked about in this run: each launch would otherwise start
  /// its server again, and wait for it, to learn the same thing.
  private let unknown = UnknownTrust()

  public init(
    agents: any AgentProviderResolving,
    tracker: TrackAgentActivity,
    consents: any AgentHookConsentStore,
    diagnostics: Diagnostics = .disabled
  ) {
    self.agents = agents
    self.tracker = tracker
    self.consents = consents
    self.diagnostics = diagnostics
  }

  public func callAsFunction(
    _ plan: AgentLaunchPlan,
    for id: SessionID,
    askConsent: AgentHookConsentRequest
  ) async -> ReportedLaunch {
    guard let provider = await agents.provider(id: plan.providerID),
      let reporting = provider as? any AgentActivityReporting
    else { return ReportedLaunch(plan: plan, decoder: nil) }
    let trusting = provider as? any AgentHookTrusting
    if trusting != nil, consents.isDeclined(plan.providerID) {
      return ReportedLaunch(plan: plan, decoder: nil)
    }
    guard let log = try? await tracker.prepareLog(for: id) else {
      record(.error, "activity.logUnavailable", plan)
      return ReportedLaunch(plan: plan, decoder: nil)
    }
    let reported = reporting.reportingActivity(plan, to: log)
    let launch = ReportedLaunch(plan: reported, decoder: reporting.activityDecoder())
    guard let trusting else { return launch }

    let fingerprint = Self.fingerprint(of: reported)
    guard consents.approvedFingerprint(for: plan.providerID) != fingerprint else { return launch }
    guard await !unknown.contains(fingerprint) else { return launch }
    switch await trusting.hookTrust(for: reported) {
    case .trusted:
      consents.setApprovedFingerprint(fingerprint, for: plan.providerID)
    case .unknown:
      // The CLI will ask for itself, in the terminal.
      await unknown.insert(fingerprint)
      record(.notice, "activity.trustUnknown", plan)
    case .needsApproval(let commands):
      let name = provider.descriptor.displayName
      switch await askConsent(name, commands) {
      case .approved:
        consents.setDeclined(false, for: plan.providerID)
      case .declined:
        consents.setDeclined(true, for: plan.providerID)
        record(.info, "activity.hooksDeclined", plan)
        return ReportedLaunch(plan: plan, decoder: nil)
      case .undecided:
        return ReportedLaunch(plan: plan, decoder: nil)
      }
      do {
        try await trusting.trustHooks(of: reported)
        consents.setApprovedFingerprint(fingerprint, for: plan.providerID)
        record(.info, "activity.hooksApproved", plan)
      } catch {
        record(.error, "activity.trustFailed", plan)
      }
    }
    return launch
  }

  /// What the approval depends on: the CLI, its version, and the hooks it is handed. Anything
  /// else in the plan — the session, the model, the prompt — changes nothing to it.
  static func fingerprint(of plan: AgentLaunchPlan) -> String {
    let version = plan.version.map { "\($0.major).\($0.minor).\($0.patch)" } ?? "?"
    // The approval lives in the configuration of this home: another home was never approved.
    let home = plan.environment["CODEX_HOME"] ?? plan.environment["HOME"] ?? ""
    let hooks = plan.arguments.enumerated().filter { index, argument in
      argument.hasPrefix("hooks.") && index > 0 && plan.arguments[index - 1] == "-c"
    }.map(\.element)
    let text = ([plan.providerID.rawValue, plan.executablePath, version, home] + hooks)
      .joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func record(_ level: DiagnosticLevel, _ name: StaticString, _ plan: AgentLaunchPlan) {
    diagnostics.record(.session, level, name, ["provider": .token(plan.providerID.diagnosticToken)])
  }
}

private actor UnknownTrust {
  private var fingerprints: Set<String> = []

  func contains(_ fingerprint: String) -> Bool {
    fingerprints.contains(fingerprint)
  }

  func insert(_ fingerprint: String) {
    fingerprints.insert(fingerprint)
  }
}
