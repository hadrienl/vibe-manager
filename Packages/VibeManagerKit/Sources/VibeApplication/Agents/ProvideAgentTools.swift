import Foundation
import VibeDomain

/// Sets a launch up with the tools of the session's web view (#69): the tool server the agent loads,
/// and, in its terminal, the `vibe` command and where its socket is.
///
/// Applied to every launch — a start, a restart, a resume, a switch — so that whichever way an agent
/// comes back, it comes back with its tools. An agent adopted from the terminal host keeps the
/// command line it was started with.
@MainActor
public struct ProvideAgentTools {
  public struct Setup: Sendable {
    public let servers: [AgentToolServer]
    /// Put in front of the terminal's `PATH`: where the `vibe` command is.
    public let pathPrefix: String?
    public let environment: [String: String]

    public init(servers: [AgentToolServer], pathPrefix: String?, environment: [String: String]) {
      self.servers = servers
      self.pathPrefix = pathPrefix
      self.environment = environment
    }
  }

  private let agents: any AgentProviderResolving
  /// `nil` when the agents are not given the web view: Settings › Web View.
  private let setup: @MainActor () -> Setup?
  /// The coordination tool server (#352), given to every session but a child; `nil` when there is
  /// none.
  private let coordination: @MainActor () -> AgentToolServer?
  /// Where the agents create their worktrees (#432): Settings › Worktrees.
  private let worktrees: @MainActor () -> WorktreeLocationSettings?

  public init(
    agents: any AgentProviderResolving, setup: @escaping @MainActor () -> Setup?,
    coordination: @escaping @MainActor () -> AgentToolServer? = { nil },
    worktrees: @escaping @MainActor () -> WorktreeLocationSettings? = { nil }
  ) {
    self.agents = agents
    self.setup = setup
    self.coordination = coordination
    self.worktrees = worktrees
  }

  /// - Parameter session: the session launched. Every session but a child gets the coordination
  ///   tools on top of the web view's (#352), whether or not agents are given the web view: they
  ///   serve once the user turns coordination on, without a restart. A session it is on for is
  ///   given the coordinator's instructions as well. Every session is told where to create its
  ///   worktrees (#432), in the same instructions: an agent takes them once.
  public func callAsFunction(_ plan: AgentLaunchPlan, for session: WorkSession? = nil) async
    -> AgentLaunchPlan
  {
    var plan = plan
    var instructions: [String] = []
    if let session, CoordinationPolicy.mayCoordinate(session), let server = coordination() {
      let provider = await agents.provider(id: plan.providerID)
      if let serving = provider as? any AgentToolServing {
        plan = serving.providingTools([server], to: plan)
      }
      if session.coordination?.isCoordinator == true {
        instructions.append(CoordinatorInstructions.text)
      }
    }
    if let session, let settings = worktrees(),
      let text = WorktreeInstructions.text(
        for: session, agent: plan.providerID, settings: settings)
    {
      instructions.append(text)
    }
    if !instructions.isEmpty,
      let instructing = await agents.provider(id: plan.providerID) as? any AgentInstructing
    {
      plan = instructing.instructing(instructions.joined(separator: "\n\n"), to: plan)
    }
    guard let setup = setup() else { return plan }
    var environment = setup.environment
    if let prefix = setup.pathPrefix {
      let path =
        plan.environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        ?? TerminalEnvironment.fallbackPath
      let parts = path.split(separator: ":").map(String.init)
      environment["PATH"] = parts.contains(prefix) ? path : "\(prefix):\(path)"
    }
    let serving = await agents.provider(id: plan.providerID) as? any AgentToolServing
    let withEnvironment = plan.adding(options: [], environment: environment)
    guard let serving else { return withEnvironment }
    return serving.providingTools(setup.servers, to: withEnvironment)
  }
}
