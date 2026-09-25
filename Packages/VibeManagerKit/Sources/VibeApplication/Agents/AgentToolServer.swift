import Foundation

/// A program an agent is started with as one of its tool servers (MCP, over its standard input and
/// output): the web view's bridge (#69).
///
/// Only a path and arguments: nothing secret goes on a command line, which every user of the Mac
/// can read.
public struct AgentToolServer: Hashable, Sendable {
  /// The name the agent knows the server by, and prefixes its tools with.
  public let name: String
  public let executablePath: String
  public let arguments: [String]

  public init(name: String, executablePath: String, arguments: [String]) {
    self.name = name
    self.executablePath = executablePath
    self.arguments = arguments
  }
}

/// Implemented by the providers whose CLI can be handed tool servers at launch.
///
/// Like the activity hooks (#45), they are passed on the command line for this launch alone: the
/// user's own configuration is never written, and a CLI started outside Vibe Manager is unchanged.
public protocol AgentToolServing: Sendable {
  /// The same plan, with `servers` added to what the CLI already loads.
  func providingTools(_ servers: [AgentToolServer], to plan: AgentLaunchPlan) -> AgentLaunchPlan
}

extension AgentLaunchPlan {
  /// The same plan with `options` placed before any `--`, where the CLI still reads options, and
  /// `environment` added to its own.
  public func adding(options: [String], environment additions: [String: String] = [:])
    -> AgentLaunchPlan
  {
    var arguments = self.arguments
    let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
    arguments.insert(contentsOf: options, at: separator)
    var environment = self.environment
    environment.merge(additions) { _, added in added }
    return AgentLaunchPlan(
      providerID: providerID,
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      workingDirectoryPath: workingDirectoryPath,
      promptDelivery: promptDelivery,
      version: version
    )
  }
}
