import VibeDomain

/// Whether an observer still reads the terminal after a piece of its output (#248).
public enum AgentOutputDemand: Sendable {
  case more
  /// It found what it was reading for: the launcher stops handing it the output.
  case enough
}

/// What watches one launch long enough to keep what makes it resumable.
///
/// The two CLIs reveal their session identifier in ways that have nothing in common — one is
/// told which identifier to use, the other has to be discovered — so the knowledge stays inside
/// each provider and only this shape crosses into the application.
public protocol AgentLaunchObserver: Sendable {
  /// Whether this observer reads the terminal at all. One that does not is never handed the
  /// output, which spares a decode of every block the agent writes (#248).
  var readsOutput: Bool { get }
  func launched(plan: AgentLaunchPlan) async
  /// The same, knowing whether the CLI will really run the hooks the plan carries: approved, or
  /// not needing an approval (#144). A plan whose hooks may still be refused in the terminal is
  /// launched with `false`.
  func launched(plan: AgentLaunchPlan, hooksApproved: Bool) async
  /// Reads a piece of the terminal's output, decoded, and says whether it wants the rest.
  func observe(output: String) async -> AgentOutputDemand
  func finished() async
  /// The identifier this launch gave its conversation and has not yet seen written down, if any:
  /// asked when the application lets go of a process the terminal host keeps, so that the next
  /// instance can keep watching for it (#141).
  func awaitedResumeIdentifier() async -> String?
  /// Takes up the watch of a process another instance of the application launched and the
  /// terminal host kept: `identifier` is the one it was still waiting for (#141). There is no plan
  /// to read it from, only what that instance wrote down.
  func adopted(awaitedResumeIdentifier identifier: String) async
  /// The agent named its conversation itself, through the hooks of this very process (#144): the
  /// one report that cannot belong to another launch. Given to the observer of a launch, and to
  /// the observer of a process adopted from the terminal host.
  func conversationNamed(_ identifier: String) async
}

extension AgentLaunchObserver {
  /// Observers read the terminal unless they say otherwise.
  public var readsOutput: Bool { true }

  public func launched(plan: AgentLaunchPlan, hooksApproved: Bool) async {
    await launched(plan: plan)
  }

  /// A CLI that is not told its identifier has none to wait for: it is discovered or it is not.
  public func awaitedResumeIdentifier() async -> String? { nil }

  public func adopted(awaitedResumeIdentifier identifier: String) async {
    // Nothing was waited for, so there is nothing to take up.
  }

  public func conversationNamed(_ identifier: String) async {
    // A CLI told its identifier up front has nothing to learn from the report.
  }
}

/// Implemented by the providers that have something to watch. A provider without it simply has
/// no identifier to keep, which is not a failure.
public protocol AgentLaunchObserverProviding: Sendable {
  func launchObserver(
    for sessionID: SessionID,
    repository: any SessionRepository
  ) -> any AgentLaunchObserver
}

/// Under which agent a launch's conversation is recorded: its own, or — for an endpoint (#107) —
/// the endpoint's, with the command line agent that ran it.
public struct AgentResumeRecording: Hashable, Sendable {
  public var providerID: String
  public var harnessID: String?

  public init(providerID: String, harnessID: String? = nil) {
    self.providerID = providerID
    self.harnessID = harnessID
  }
}

/// Implemented by the providers that must do something just before their process starts, and not
/// before: an endpoint starts its gateway and gives the session its token (#107). A plan is also
/// built to validate a form, many times; a launch is prepared once, when it happens.
public protocol AgentLaunchPreparing: Sendable {
  /// The plan as it will run, or an error the session shows instead of starting.
  func preparingLaunch(_ plan: AgentLaunchPlan, session: SessionID) async throws -> AgentLaunchPlan
}

/// Prepares a launch with its provider, when the provider has something to prepare.
public struct PrepareAgentLaunch: Sendable {
  private let agents: any AgentProviderResolving

  public init(agents: any AgentProviderResolving) {
    self.agents = agents
  }

  public func callAsFunction(_ plan: AgentLaunchPlan, session: SessionID) async throws
    -> AgentLaunchPlan
  {
    guard let preparing = await agents.provider(id: plan.providerID) as? any AgentLaunchPreparing
    else { return plan }
    return try await preparing.preparingLaunch(plan, session: session)
  }
}
