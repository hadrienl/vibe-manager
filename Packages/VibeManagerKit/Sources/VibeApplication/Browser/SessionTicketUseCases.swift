import Foundation
import VibeDomain

/// What a session's ticket is deduced from: the branch its working folder is on, and where that
/// repository lives on its forge (#69).
public struct TicketContext: Hashable, Sendable {
  public let branch: String?
  public let repository: RepositoryWebAddress?

  public init(branch: String?, repository: RepositoryWebAddress?) {
    self.branch = branch
    self.repository = repository
  }

  public static let none = TicketContext(branch: nil, repository: nil)
}

/// Asks Git, read only, for a folder's branch and its `origin`.
public struct ReadTicketContext: Sendable {
  private let git: any GitCommandRunner

  public init(git: any GitCommandRunner) {
    self.git = git
  }

  public func callAsFunction(path: String) async -> TicketContext {
    let branch = try? await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: path)
    let remote = try? await git.run(["remote", "get-url", "origin"], in: path)
    return TicketContext(
      branch: branch.flatMap { $0.succeeded && !$0.text.isEmpty ? $0.text : nil },
      repository: remote.flatMap { $0.succeeded ? RepositoryWebAddress.of(remote: $0.text) : nil })
  }
}

/// Writes the ticket a person chose for a session: typed, or taken from a tab. `nil` removes it on
/// purpose, so that the branch does not bring it back.
public struct SetSessionTicket: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  @discardableResult
  public func callAsFunction(_ url: URL?, for id: SessionID) async throws -> WorkSession? {
    try await repository.mutate(id: id) { session in
      session.ticket = url.map { SessionTicket(url: $0, source: .manual) } ?? .removed
    }
  }

  /// Forgets what was chosen: the branch decides again.
  @discardableResult
  public func reset(for id: SessionID) async throws -> WorkSession? {
    try await repository.mutate(id: id) { session in
      session.ticket = nil
    }
  }
}
