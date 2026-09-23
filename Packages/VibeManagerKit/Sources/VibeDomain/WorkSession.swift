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
    startedAt: Date? = nil
  ) {
    self.status = status
    let createdAt = createdAt.storageRounded
    let updatedAt = updatedAt.storageRounded
    let closedAt = closedAt?.storageRounded
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.closedAt = closedAt
    self.archivedAt = archivedAt?.storageRounded
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

/// How a folder takes part in a session.
public enum RepositoryAttachmentMode: String, Hashable, Codable, Sendable, CaseIterable {
  /// A worktree of the repository, on the session's branch, under the worktree root. The default
  /// for a Git repository: the clone the user designated is never touched.
  case worktree
  /// The clone itself, on whatever branch it is on. What every session stored before worktrees
  /// existed does, and what a user chooses when the clone is the place they want the work.
  case inPlace
  /// A folder without Git — notes, data. It has its place in a session, with no branch and no
  /// convention.
  case plainFolder
}

/// Why a repository attached to a session could not be prepared, kept on it so the inspector and
/// the next restart can say so.
///
/// A sentence and a remedy, like `SessionDraftIssue`: the same shape renders in the sheet, the
/// inspector and the restart banner.
public struct RepositoryPreparationFailure: Hashable, Codable, Sendable {
  public var message: String
  public var remedy: String

  public init(message: String, remedy: String) {
    self.message = message
    self.remedy = remedy
  }
}

/// One folder attached to a session: the clone it came from, and the place the work happens.
/// The branches of a repository at one instant: what a session's report is measured against.
///
/// Every local branch with the commit it names, the branch checked out and the `HEAD`. A dated
/// photograph, like `GitSnapshot`: nothing here is kept up to date.
public struct GitReferenceSnapshot: Hashable, Codable, Sendable {
  public var checkedOutBranch: String?
  public var headRevision: String?
  public var branches: [String: String]
  public var isDirty: Bool
  public var capturedAt: Date {
    didSet { capturedAt = capturedAt.storageRounded }
  }

  public init(
    checkedOutBranch: String?,
    headRevision: String?,
    branches: [String: String],
    isDirty: Bool = false,
    capturedAt: Date = Date()
  ) {
    self.checkedOutBranch = checkedOutBranch
    self.headRevision = headRevision
    self.branches = branches
    self.isDirty = isDirty
    self.capturedAt = capturedAt.storageRounded
  }

  private enum CodingKeys: String, CodingKey {
    case checkedOutBranch, headRevision, branches, isDirty, capturedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      checkedOutBranch: try container.decodeIfPresent(String.self, forKey: .checkedOutBranch),
      headRevision: try container.decodeIfPresent(String.self, forKey: .headRevision),
      branches: try container.decode([String: String].self, forKey: .branches),
      isDirty: try container.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false,
      capturedAt: try container.decode(Date.self, forKey: .capturedAt)
    )
  }
}

public struct RepositoryContext: Identifiable, Hashable, Codable, Sendable {
  public let id: RepositoryID
  /// The clone the user designated. Never moved, and the path the session is grouped by — so a
  /// session working in a worktree stays filed with its project.
  public var rootPath: String
  public var mode: RepositoryAttachmentMode
  /// Where the worktree is, for `worktree`. `nil` otherwise, and `nil` for a worktree that could
  /// not be prepared.
  public var worktreePath: String?
  /// The branch the work happens on. The session's branch for a worktree, the clone's own for a
  /// repository attached in place, `nil` for a plain folder or a detached `HEAD`.
  public var branchName: String?
  /// What the branch started from, when Vibe Manager created it.
  public var baseRevision: String?
  /// `false` when an existing worktree was adopted: the application did not make it, and must
  /// not suggest it did — least of all in the cleanup command it offers.
  public var createdByVibeManager: Bool
  public var attachedAt: Date? {
    didSet { attachedAt = attachedAt?.storageRounded }
  }
  /// Set when preparing this repository failed. The session exists anyway: one repository that
  /// refuses does not take the others down.
  public var failure: RepositoryPreparationFailure?
  /// The branches as they were when an agent first ran for this session: what the report of what
  /// the agent created or moved is measured against. Taken once, never on a restart.
  public var baseline: GitReferenceSnapshot?
  public var git: GitSnapshot?

  public init(
    id: RepositoryID = RepositoryID(),
    rootPath: String,
    mode: RepositoryAttachmentMode = .inPlace,
    worktreePath: String? = nil,
    branchName: String? = nil,
    baseRevision: String? = nil,
    createdByVibeManager: Bool = false,
    attachedAt: Date? = nil,
    failure: RepositoryPreparationFailure? = nil,
    baseline: GitReferenceSnapshot? = nil,
    git: GitSnapshot? = nil
  ) {
    self.id = id
    self.rootPath = rootPath
    self.mode = mode
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.baseRevision = baseRevision
    self.createdByVibeManager = createdByVibeManager
    self.attachedAt = attachedAt?.storageRounded
    self.failure = failure
    self.baseline = baseline
    self.git = git
  }

  /// Where the agent works for this repository: the worktree when there is one, the folder
  /// itself otherwise. `nil` for a worktree that was never prepared — sending the agent into the
  /// clone instead would be exactly what the worktree was meant to avoid.
  public var effectivePath: String? {
    switch mode {
    case .worktree:
      return failure == nil ? worktreePath : nil
    case .inPlace, .plainFolder:
      return failure == nil ? rootPath : nil
    }
  }

  /// The last component of the clone's path, which is what the rows and the convention call it.
  public var displayName: String {
    let component = URL(fileURLWithPath: rootPath).lastPathComponent
    return component.isEmpty ? rootPath : component
  }

  private enum CodingKeys: String, CodingKey {
    case id, rootPath, mode, worktreePath, branchName, baseRevision, createdByVibeManager
    case attachedAt, failure, baseline, git
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(RepositoryID.self, forKey: .id),
      rootPath: try container.decode(String.self, forKey: .rootPath),
      mode: try container.decode(RepositoryAttachmentMode.self, forKey: .mode),
      worktreePath: try container.decodeIfPresent(String.self, forKey: .worktreePath),
      branchName: try container.decodeIfPresent(String.self, forKey: .branchName),
      baseRevision: try container.decodeIfPresent(String.self, forKey: .baseRevision),
      createdByVibeManager: try container.decode(Bool.self, forKey: .createdByVibeManager),
      attachedAt: try container.decodeIfPresent(Date.self, forKey: .attachedAt),
      failure: try container.decodeIfPresent(
        RepositoryPreparationFailure.self, forKey: .failure),
      baseline: try container.decodeIfPresent(GitReferenceSnapshot.self, forKey: .baseline),
      git: try container.decodeIfPresent(GitSnapshot.self, forKey: .git)
    )
  }
}

public enum WorkSessionValidationError: Error, Equatable, Sendable {
  case emptyName
  case emptyAgentIdentifier
  case invalidAppearance
  case invalidLifecycle
  case duplicateRepositoryIdentifier
  case emptyRepositoryPath
  case invalidRepositoryAttachment
}

public struct WorkSession: Identifiable, Hashable, Codable, Sendable {
  public let id: SessionID
  public var name: String
  public var initialPrompt: String
  public var agent: SessionAgentConfiguration?
  public var appearance: SessionAppearance
  public private(set) var lifecycle: SessionLifecycle
  /// The first repository is the main one: the agent is started in it.
  public var repositories: [RepositoryContext]
  /// The name of the session's branch and worktree folder, fixed at creation. `nil` for a session
  /// stored before worktrees existed, which works in its folders in place — until the first
  /// worktree is attached to it, which is the one moment it is given one.
  public private(set) var slug: SessionSlug?
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
    slug: SessionSlug? = nil,
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
      archivedAt: archivedAt,
      startedAt: startedAt
    )
    self.repositories = repositories
    self.slug = slug
    self.notes = notes
    self.template = template
  }

  /// Gives a session stored without a slug the one it will keep. A slug already there is never
  /// replaced: renaming a session must not rename its branch.
  public mutating func adoptSlugIfMissing(_ candidate: SessionSlug) {
    guard slug == nil else { return }
    slug = candidate
  }

  /// Records that something about the session changed — a repository attached or detached —
  /// without moving it through its lifecycle.
  public mutating func touch(at date: Date) throws {
    try lifecycle.touch(at: date)
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
    guard Set(repositories.map(\.id)).count == repositories.count else {
      throw WorkSessionValidationError.duplicateRepositoryIdentifier
    }
    guard repositories.allSatisfy({ !$0.rootPath.isEmpty }) else {
      throw WorkSessionValidationError.emptyRepositoryPath
    }
    guard repositories.allSatisfy(Self.isValidAttachment) else {
      throw WorkSessionValidationError.invalidRepositoryAttachment
    }
  }

  /// The folder this session's worktrees were made in, read from the worktrees themselves.
  ///
  /// Not recomputed from the current root: the root is a setting, and a session whose worktrees
  /// were made before it changed still lives where they are.
  public var worktreeFolderPath: String? {
    guard let slug else { return nil }
    for repository in repositories where repository.createdByVibeManager {
      guard let path = repository.worktreePath else { continue }
      let folder = (path as NSString).deletingLastPathComponent
      if (folder as NSString).lastPathComponent == slug.rawValue { return folder }
    }
    return nil
  }

  /// The repository the agent is started in: the first one that can be worked in.
  ///
  /// The first one, full stop, is the *main* repository; this is it only when it is usable. The
  /// callers that launch decide what to do when it is not — refusing, most of the time.
  public var mainRepository: RepositoryContext? {
    repositories.first
  }

  /// A plain folder carries no branch, and a worktree that was prepared has one.
  private static func isValidAttachment(_ repository: RepositoryContext) -> Bool {
    switch repository.mode {
    case .plainFolder:
      return repository.worktreePath == nil && repository.branchName == nil
    case .worktree:
      guard repository.failure == nil else { return true }
      return repository.worktreePath.map { !$0.isEmpty } ?? false
    case .inPlace:
      return repository.worktreePath == nil
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
