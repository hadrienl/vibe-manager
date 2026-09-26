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
  /// When an agent first ran for this session, and `nil` for one that has never run.
  ///
  /// Recorded rather than derived: a created session is stored closed, with its whole lifecycle
  /// sitting on its creation date, so `closedAt` on its own cannot tell a session that was never
  /// started from one that was worked in and closed.
  public private(set) var startedAt: Date?

  public init(
    status: SessionStatus = .closed,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    closedAt: Date? = nil,
    archivedAt: Date? = nil,
    startedAt: Date? = nil,
    /// `false` takes a `nil` start at its word: never started. A store that records the start of
    /// every session it writes says so (schema v6); an older one leaves it to be inferred.
    infersStartedAt: Bool = true
  ) {
    self.status = status
    let createdAt = createdAt.storageRounded
    let updatedAt = updatedAt.storageRounded
    let closedAt = closedAt?.storageRounded
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.closedAt = closedAt
    self.archivedAt = archivedAt?.storageRounded
    guard infersStartedAt || startedAt != nil else {
      self.startedAt = nil
      return
    }
    self.startedAt =
      startedAt?.storageRounded
      ?? Self.inferredStartedAt(
        status: status,
        createdAt: createdAt,
        updatedAt: updatedAt,
        closedAt: closedAt
      )
  }

  /// What a lifecycle written before this date was kept says about it.
  ///
  /// Every stored session would otherwise read as never started, and be offered a first launch
  /// with its initial prompt in place of the restart it is owed. Only one shape means "never
  /// launched" — stored at creation, closed on the same instant, untouched since — and every
  /// other one has run at least once.
  private static func inferredStartedAt(
    status: SessionStatus,
    createdAt: Date,
    updatedAt: Date,
    closedAt: Date?
  ) -> Date? {
    switch status {
    case .active:
      return createdAt
    case .closed:
      if closedAt == createdAt, updatedAt == createdAt { return nil }
      return closedAt ?? createdAt
    case .archived:
      return closedAt ?? createdAt
    }
  }

  private enum CodingKeys: String, CodingKey {
    case status, createdAt, updatedAt, closedAt, archivedAt, startedAt
  }

  /// Decoding routes through the designated initializer so that a value read back from any
  /// encoded form carries the same precision as one built in memory.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      status: try container.decode(SessionStatus.self, forKey: .status),
      createdAt: try container.decode(Date.self, forKey: .createdAt),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt),
      closedAt: try container.decodeIfPresent(Date.self, forKey: .closedAt),
      archivedAt: try container.decodeIfPresent(Date.self, forKey: .archivedAt),
      startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt)
    )
  }

  public mutating func close(at date: Date) throws {
    let date = date.storageRounded
    try transition(from: .active, to: .closed, at: date)
    closedAt = date
    archivedAt = nil
  }

  public mutating func reopen(at date: Date) throws {
    let date = date.storageRounded
    try transition(from: .closed, to: .active, at: date)
    closedAt = nil
    archivedAt = nil
    // The first agent this session ever ran is what this records, so a later restart never
    // overwrites it.
    if startedAt == nil { startedAt = date }
  }

  public mutating func archive(at date: Date) throws {
    let date = date.storageRounded
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
    let date = date.storageRounded
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
  /// `nil` is "whatever the agent is configured to use", which is a real state: neither CLI
  /// guarantees a model catalogue, and a sentinel such as `"default"` would eventually be passed
  /// to `--model` as if it named a model.
  public var modelID: String?
  public var resumeIdentifier: String?

  public init(providerID: String, modelID: String? = nil, resumeIdentifier: String? = nil) {
    self.providerID = providerID
    self.modelID = modelID
    self.resumeIdentifier = resumeIdentifier
  }
}

public struct SessionAppearance: Hashable, Codable, Sendable {
  public var symbolName: String
  public var colorHex: String
  /// The project's own icon, copied into the data folder when the session was created (#27).
  ///
  /// The image comes first when there is one. The symbol and the colour are always filled in all
  /// the same, with what the name would have given: a badge whose file has gone — a store copied
  /// without its folder, a file removed by hand — falls back on them without a word.
  public var iconID: SessionIconID?

  public init(
    symbolName: String = "terminal",
    colorHex: String = "#5E5CE6",
    iconID: SessionIconID? = nil
  ) {
    self.symbolName = symbolName
    self.colorHex = colorHex
    self.iconID = iconID
  }
}

/// A project icon, named by the SHA-256 of the PNG it was turned into.
///
/// Named by its content, so that every session of a folder shares one file and importing the same
/// icon twice writes nothing. The name becomes a file name: only the 64 lowercase hexadecimal
/// digits of a digest are accepted, so a value read from the store can never point elsewhere.
public struct SessionIconID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let sha256: String

  public init?(sha256: String) {
    guard sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    self.sha256 = sha256
  }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    guard let id = SessionIconID(sha256: value) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath, debugDescription: "Not a SHA-256 digest"))
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(sha256)
  }

  public var description: String { sha256 }
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
  public var capturedAt: Date {
    didSet { capturedAt = capturedAt.storageRounded }
  }

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
    self.capturedAt = capturedAt.storageRounded
  }

  private enum CodingKeys: String, CodingKey {
    case repositoryRootPath, worktreePath, branchName, headRevision, isDirty, capturedAt
  }

  /// See `SessionLifecycle.init(from:)`: a synthesized decode would write `capturedAt` directly,
  /// bypassing both the initializer and the property observer.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      repositoryRootPath: try container.decode(String.self, forKey: .repositoryRootPath),
      worktreePath: try container.decodeIfPresent(String.self, forKey: .worktreePath),
      branchName: try container.decodeIfPresent(String.self, forKey: .branchName),
      headRevision: try container.decodeIfPresent(String.self, forKey: .headRevision),
      isDirty: try container.decode(Bool.self, forKey: .isDirty),
      capturedAt: try container.decode(Date.self, forKey: .capturedAt)
    )
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
  /// Archived as a task and not as a process, or the other way round.
  case invalidTaskStatus
  case duplicateRepositoryIdentifier
  case emptyRepositoryPath
}

public struct WorkSession: Identifiable, Hashable, Codable, Sendable {
  public let id: SessionID
  public var name: String
  public var initialPrompt: String
  public var agent: SessionAgentConfiguration?
  public var appearance: SessionAppearance
  public private(set) var lifecycle: SessionLifecycle
  public var repositories: [RepositoryContext]
  /// The notes a store written before #16 held inside the session. Nothing writes it any more:
  /// notes live in their own store, and this is only read once, to import them there.
  public var legacyNotes: String?
  public var template: PromptTemplateReference?
  /// Every switch of agent or model, oldest first. Appended to and never rewritten, except for the
  /// outcome of the last one when it is undone.
  public private(set) var agentHistory: [AgentChange]
  /// The ticket this session works on, when someone said which (#69). `nil` leaves it to the
  /// branch.
  public var ticket: SessionTicket?
  /// Where the work stands (#80). Changed by `setTaskStatus`, and by archiving and unarchiving,
  /// which are the only moves that touch the process as well.
  public private(set) var taskStatus: SessionTaskStatus

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

  public var startedAt: Date? {
    lifecycle.startedAt
  }

  /// Whether an agent has ever run for this session. A session that has not is started, not
  /// restarted, and it is handed the prompt it was created with rather than a summary.
  public var hasEverStarted: Bool {
    lifecycle.startedAt != nil
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
    startedAt: Date? = nil,
    repositories: [RepositoryContext] = [],
    legacyNotes: String? = nil,
    template: PromptTemplateReference? = nil,
    agentHistory: [AgentChange] = [],
    ticket: SessionTicket? = nil,
    /// `nil` reads it from the lifecycle, as for a session stored before it existed.
    taskStatus: SessionTaskStatus? = nil,
    /// See `SessionLifecycle.init`: whether a `nil` start is inferred or means never started.
    infersStartedAt: Bool = true
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
      archivedAt: archivedAt,
      startedAt: startedAt,
      infersStartedAt: infersStartedAt
    )
    self.repositories = repositories
    self.legacyNotes = legacyNotes
    self.template = template
    self.agentHistory = agentHistory
    self.ticket = ticket
    self.taskStatus =
      taskStatus
      ?? SessionTaskStatus.inferred(from: status, hasEverStarted: lifecycle.startedAt != nil)
  }

  public mutating func close(at date: Date) throws {
    try lifecycle.close(at: date)
  }

  public mutating func reopen(at date: Date) throws {
    try lifecycle.reopen(at: date)
  }

  public mutating func archive(at date: Date) throws {
    try lifecycle.archive(at: date)
    taskStatus = .archived
  }

  /// An unarchived session comes back finished: it was archived from Done, or on its way out.
  public mutating func restore(at date: Date) throws {
    try lifecycle.restore(at: date)
    taskStatus = .done
  }

  /// Moves the session between the four columns. The process is left alone: marking a task done
  /// does not stop an agent that may still be writing its summary.
  ///
  /// The session is touched, so that it arrives at the top of a column sorted by last activity.
  public mutating func setTaskStatus(_ newStatus: SessionTaskStatus, at date: Date) throws {
    guard newStatus != taskStatus else { return }
    guard newStatus != .archived, taskStatus != .archived else {
      throw SessionTaskStatusError.requiresLifecycleChange(from: taskStatus, to: newStatus)
    }
    try lifecycle.touch(at: date)
    taskStatus = newStatus
  }

  /// Every conversation this session has had, oldest first — the agents it was switched away from,
  /// then the current one. Only those that were given an identifier: a conversation that never
  /// had one left nothing that could be read back.
  public var conversations: [SessionAgentConfiguration] {
    var result: [SessionAgentConfiguration] = []
    func add(_ agent: SessionAgentConfiguration?) {
      guard let agent, let identifier = agent.resumeIdentifier, !identifier.isEmpty else { return }
      guard
        !result.contains(where: {
          $0.providerID == agent.providerID && $0.resumeIdentifier == identifier
        })
      else { return }
      result.append(agent)
    }
    for change in agentHistory { add(change.previous) }
    add(agent)
    return result
  }

  /// Hands the session to another agent or model, keeping the one it leaves in the history.
  ///
  /// Neither the lifecycle nor anything else the user wrote is touched: the lifecycle records when
  /// agents ran, which `reopen` will say, and the history records which ones.
  @discardableResult
  public mutating func switchAgent(
    to next: SessionAgentConfiguration,
    handover: AgentChange.Handover,
    at date: Date,
    id: UUID = UUID()
  ) throws -> AgentChange {
    guard status == .closed else { throw AgentSwitchError.notClosed(status) }
    guard let previous = agent else { throw AgentSwitchError.noAgent }
    guard previous.providerID != next.providerID || previous.modelID != next.modelID else {
      throw AgentSwitchError.nothingToChange
    }
    let change = AgentChange(
      id: id,
      date: date,
      previous: previous,
      next: next,
      handover: handover
    )
    agentHistory.append(change)
    agent = next
    return change
  }

  /// Puts the session back on the agent the last switch left, because the next one never ran.
  ///
  /// The entry stays, marked failed: the switch was attempted, and the history says so.
  public mutating func revertAgentSwitch(_ id: UUID, reason: String) throws {
    guard status == .closed else { throw AgentSwitchError.notClosed(status) }
    guard let index = agentHistory.indices.last, agentHistory[index].id == id,
      agentHistory[index].outcome == .completed
    else { throw AgentSwitchError.notRevertible }
    agentHistory[index].outcome = .failed(reason: reason)
    agent = agentHistory[index].previous
  }

  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkSessionValidationError.emptyName
    }
    if let agent {
      guard !agent.providerID.isEmpty, agent.modelID.map({ !$0.isEmpty }) ?? true else {
        throw WorkSessionValidationError.emptyAgentIdentifier
      }
    }
    guard Self.isValidAppearance(appearance) else {
      throw WorkSessionValidationError.invalidAppearance
    }
    guard Self.isValidLifecycle(lifecycle) else {
      throw WorkSessionValidationError.invalidLifecycle
    }
    guard (taskStatus == .archived) == (lifecycle.status == .archived) else {
      throw WorkSessionValidationError.invalidTaskStatus
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
    if let startedAt = lifecycle.startedAt {
      guard startedAt >= lifecycle.createdAt, startedAt <= lifecycle.updatedAt else {
        return false
      }
    } else if lifecycle.status == .active {
      // A running session has an agent, and an agent means it was started.
      return false
    }
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
