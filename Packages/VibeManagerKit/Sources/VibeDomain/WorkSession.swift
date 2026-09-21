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

public enum SessionTransitionError: Error, Equatable, Sendable {
  case invalidTransition(from: SessionStatus, to: SessionStatus)
  case datePrecedesLastUpdate
}

public struct SessionLifecycle: Hashable, Codable, Sendable {
  public private(set) var status: SessionStatus
  public let createdAt: Date
  public private(set) var updatedAt: Date
  public private(set) var closedAt: Date?
  public private(set) var archivedAt: Date?

  public init(
    status: SessionStatus = .closed,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    closedAt: Date? = nil,
    archivedAt: Date? = nil
  ) {
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.closedAt = closedAt
    self.archivedAt = archivedAt
  }

  public mutating func close(at date: Date) throws {
    try transition(from: .active, to: .closed, at: date)
    closedAt = date
    archivedAt = nil
  }

  public mutating func reopen(at date: Date) throws {
    try transition(from: .closed, to: .active, at: date)
    closedAt = nil
    archivedAt = nil
  }

  public mutating func archive(at date: Date) throws {
    let effectiveClosedAt = closedAt ?? updatedAt
    try transition(from: .closed, to: .archived, at: date)
    closedAt = effectiveClosedAt
    archivedAt = date
  }

  public mutating func restore(at date: Date) throws {
    try transition(from: .archived, to: .closed, at: date)
    archivedAt = nil
  }

  public mutating func touch(at date: Date) throws {
    guard date >= updatedAt else {
      throw SessionTransitionError.datePrecedesLastUpdate
    }
    updatedAt = date
  }

  private mutating func transition(
    from expectedStatus: SessionStatus,
    to newStatus: SessionStatus,
    at date: Date
  ) throws {
    guard status == expectedStatus else {
      throw SessionTransitionError.invalidTransition(from: status, to: newStatus)
    }
    try touch(at: date)
    status = newStatus
  }
}

public struct SessionAgentConfiguration: Hashable, Codable, Sendable {
  public var providerID: String
  public var modelID: String
  public var resumeIdentifier: String?

  public init(providerID: String, modelID: String, resumeIdentifier: String? = nil) {
    self.providerID = providerID
    self.modelID = modelID
    self.resumeIdentifier = resumeIdentifier
  }
}

public struct SessionAppearance: Hashable, Codable, Sendable {
  public var symbolName: String
  public var colorHex: String

  public init(symbolName: String = "terminal", colorHex: String = "#5E5CE6") {
    self.symbolName = symbolName
    self.colorHex = colorHex
  }
}

public struct PromptTemplateReference: Hashable, Codable, Sendable {
  public let id: String
  public var name: String
  public var revision: String?

  public init(id: String, name: String, revision: String? = nil) {
    self.id = id
    self.name = name
    self.revision = revision
  }
}

public struct RepositoryID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString
  }
}

public struct GitSnapshot: Hashable, Codable, Sendable {
  public var repositoryRootPath: String
  public var worktreePath: String?
  public var branchName: String?
  public var headRevision: String?
  public var isDirty: Bool
  public var capturedAt: Date

  public init(
    repositoryRootPath: String,
    worktreePath: String? = nil,
    branchName: String? = nil,
    headRevision: String? = nil,
    isDirty: Bool = false,
    capturedAt: Date = Date()
  ) {
    self.repositoryRootPath = repositoryRootPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.headRevision = headRevision
    self.isDirty = isDirty
    self.capturedAt = capturedAt
  }
}

public struct RepositoryContext: Identifiable, Hashable, Codable, Sendable {
  public let id: RepositoryID
  public var path: String
  public var git: GitSnapshot?

  public init(id: RepositoryID = RepositoryID(), path: String, git: GitSnapshot? = nil) {
    self.id = id
    self.path = path
    self.git = git
  }
}

public enum WorkSessionValidationError: Error, Equatable, Sendable {
  case emptyName
  case emptyAgentIdentifier
  case invalidAppearance
  case invalidLifecycle
  case duplicateRepositoryIdentifier
  case emptyRepositoryPath
}

public struct WorkSession: Identifiable, Hashable, Codable, Sendable {
  public let id: SessionID
  public var name: String
  public var initialPrompt: String
  public var agent: SessionAgentConfiguration?
  public var appearance: SessionAppearance
  public var lifecycle: SessionLifecycle
  public var repositories: [RepositoryContext]
  public var notes: String?
  public var template: PromptTemplateReference?

  public var status: SessionStatus {
    lifecycle.status
  }

  public var createdAt: Date {
    lifecycle.createdAt
  }

  public var updatedAt: Date {
    lifecycle.updatedAt
  }

  public var closedAt: Date? {
    lifecycle.closedAt
  }

  public var archivedAt: Date? {
    lifecycle.archivedAt
  }

  public init(
    id: SessionID = SessionID(),
    name: String,
    initialPrompt: String = "",
    agent: SessionAgentConfiguration? = nil,
    appearance: SessionAppearance = SessionAppearance(),
    status: SessionStatus = .closed,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    closedAt: Date? = nil,
    archivedAt: Date? = nil,
    repositories: [RepositoryContext] = [],
    notes: String? = nil,
    template: PromptTemplateReference? = nil
  ) {
    self.id = id
    self.name = name
    self.initialPrompt = initialPrompt
    self.agent = agent
    self.appearance = appearance
    lifecycle = SessionLifecycle(
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
      closedAt: closedAt,
      archivedAt: archivedAt
    )
    self.repositories = repositories
    self.notes = notes
    self.template = template
  }

  public mutating func close(at date: Date) throws {
    try lifecycle.close(at: date)
  }

  public mutating func reopen(at date: Date) throws {
    try lifecycle.reopen(at: date)
  }

  public mutating func archive(at date: Date) throws {
    try lifecycle.archive(at: date)
  }

  public mutating func restore(at date: Date) throws {
    try lifecycle.restore(at: date)
  }

  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkSessionValidationError.emptyName
    }
    if let agent {
      guard !agent.providerID.isEmpty, !agent.modelID.isEmpty else {
        throw WorkSessionValidationError.emptyAgentIdentifier
      }
    }
    guard Self.isValidAppearance(appearance) else {
      throw WorkSessionValidationError.invalidAppearance
    }
    guard Self.isValidLifecycle(lifecycle) else {
      throw WorkSessionValidationError.invalidLifecycle
    }
    guard Set(repositories.map(\.id)).count == repositories.count else {
      throw WorkSessionValidationError.duplicateRepositoryIdentifier
    }
    guard repositories.allSatisfy({ !$0.path.isEmpty }) else {
      throw WorkSessionValidationError.emptyRepositoryPath
    }
  }

  private static func isValidAppearance(_ appearance: SessionAppearance) -> Bool {
    guard !appearance.symbolName.isEmpty else { return false }
    let color = appearance.colorHex
    guard color.count == 7 || color.count == 9, color.first == "#" else { return false }
    return color.dropFirst().allSatisfy(\.isHexDigit)
  }

  private static func isValidLifecycle(_ lifecycle: SessionLifecycle) -> Bool {
    guard lifecycle.updatedAt >= lifecycle.createdAt else { return false }
    switch lifecycle.status {
    case .active:
      return lifecycle.closedAt == nil && lifecycle.archivedAt == nil
    case .closed:
      guard lifecycle.archivedAt == nil else { return false }
      return lifecycle.closedAt.map { $0 >= lifecycle.createdAt && $0 <= lifecycle.updatedAt }
        ?? true
    case .archived:
      guard let closedAt = lifecycle.closedAt, let archivedAt = lifecycle.archivedAt else {
        return false
      }
      return closedAt >= lifecycle.createdAt && archivedAt >= closedAt
        && archivedAt <= lifecycle.updatedAt
    }
  }
}
