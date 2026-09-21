import Foundation

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString
  }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case active
  case closed
  case archived
}

public struct WorkSession: Identifiable, Hashable, Codable, Sendable {
  public let id: SessionID
  public var name: String
  public var status: SessionStatus
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: SessionID = SessionID(),
    name: String,
    status: SessionStatus = .closed,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
