import Foundation
import VibeDomain

public protocol SessionClock: Sendable {
  func now() -> Date
}

public struct SystemSessionClock: SessionClock {
  public init() {}

  public func now() -> Date {
    Date()
  }
}

public enum SessionLifecycleAction: Sendable {
  case close
  case reopen
  case archive
  case restore
}

public enum ChangeSessionStatusError: Error, Equatable, Sendable {
  case sessionNotFound(SessionID)
}

public struct ChangeSessionStatus: Sendable {
  private let repository: any SessionRepository
  private let clock: any SessionClock

  public init(
    repository: any SessionRepository,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.repository = repository
    self.clock = clock
  }

  public func callAsFunction(
    id: SessionID,
    action: SessionLifecycleAction
  ) async throws -> WorkSession {
    let date = clock.now()
    let updated = try await repository.mutate(id: id) { session in
      switch action {
      case .close:
        try session.close(at: date)
      case .reopen:
        try session.reopen(at: date)
      case .archive:
        try session.archive(at: date)
      case .restore:
        try session.restore(at: date)
      }
    }

    guard let updated else {
      throw ChangeSessionStatusError.sessionNotFound(id)
    }
    return updated
  }
}
