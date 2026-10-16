import Foundation
import VibeDomain

/// Turns coordination on or off for a session, from its message field (#352). A child's is never
/// turned on; the children of a session turned off stay its own.
public struct SetSessionCoordinating: Sendable {
  private let repository: any SessionRepository

  public init(repository: any SessionRepository) {
    self.repository = repository
  }

  @discardableResult
  public func callAsFunction(_ isOn: Bool, for id: SessionID) async throws -> WorkSession? {
    try await repository.mutate(id: id) { session in
      guard CoordinationPolicy.mayCoordinate(session) else { return }
      session.coordination = isOn ? .coordinator : nil
    }
  }
}
