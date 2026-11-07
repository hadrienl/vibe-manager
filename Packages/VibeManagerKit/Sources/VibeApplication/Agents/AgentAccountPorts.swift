import Foundation
import VibeDomain

/// Where the agents' extra accounts are kept (#478).
public protocol AgentAccountRepository: Sendable {
  /// In the user's order; empty when nothing was ever saved.
  func accounts() async throws -> [AgentAccount]
  func save(_ accounts: [AgentAccount]) async throws
}

public enum AgentAccountStoreError: Error, Equatable, Sendable, LocalizedError {
  /// The file is there but could not be read, or was written by a newer version. It is never
  /// written over.
  case unreadable(reason: String)
  case cannotWrite(reason: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let reason):
      return String(localized: "Accounts couldn't be read: \(reason)", bundle: .module)
    case .cannotWrite(let reason):
      return String(localized: "Accounts couldn't be saved: \(reason)", bundle: .module)
    }
  }
}

public actor InMemoryAgentAccountRepository: AgentAccountRepository {
  private var stored: [AgentAccount]

  public init(_ accounts: [AgentAccount] = []) {
    stored = accounts
  }

  public func accounts() -> [AgentAccount] { stored }
  public func save(_ accounts: [AgentAccount]) { stored = accounts }
}
