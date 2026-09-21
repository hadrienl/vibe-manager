import VibeDomain

public struct AgentDescriptor: Hashable, Sendable {
  public let id: String
  public let displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public enum AgentAvailability: Equatable, Sendable {
  case available(version: String)
  case unavailable(reason: String)
}

public protocol AgentProvider: Sendable {
  var descriptor: AgentDescriptor { get }
  func availability() async -> AgentAvailability
}
