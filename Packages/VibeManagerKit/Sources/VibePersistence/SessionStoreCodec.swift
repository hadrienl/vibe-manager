import Foundation
import VibeDomain

enum SessionStoreCodecError: Error, Equatable {
  case unsupportedSchemaVersion(Int)
  case invalidStore
}

struct SessionStoreDecodeResult {
  let sessions: [WorkSession]
  let requiresRewrite: Bool
}

struct SessionStoreCodec {
  static let currentSchemaVersion = 3

  func encode(sessions: [WorkSession], savedAt: Date = Date()) throws -> Data {
    try validate(sessions)
    let envelope = StoreEnvelopeV3(
      schemaVersion: Self.currentSchemaVersion,
      savedAt: savedAt,
      sessions: sessions.map(StoredSessionV3.init)
    )
    return try Self.makeEncoder().encode(envelope)
  }

  func decode(_ data: Data) throws -> SessionStoreDecodeResult {
    let probe: StoreVersionProbe
    do {
      probe = try JSONDecoder().decode(StoreVersionProbe.self, from: data)
    } catch {
      throw SessionStoreCodecError.invalidStore
    }

    let sessions: [WorkSession]
    let requiresRewrite: Bool
    do {
      switch probe.schemaVersion {
      case 0:
        let legacy = try Self.makeDecoder().decode(StoreEnvelopeV0.self, from: data)
        sessions = legacy.sessions.map(\.workSession)
        requiresRewrite = true
      case 1:
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV1.self, from: data)
        sessions = previous.sessions.map(\.workSession)
        requiresRewrite = true
      case 2:
        // Every v2 session works in its folder, on that folder's branch: exactly what `inPlace`
        // describes. Nothing on disk is looked at or created to read it.
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV2.self, from: data)
        sessions = previous.sessions.map(\.workSession)
        requiresRewrite = true
      case Self.currentSchemaVersion:
        let current = try Self.makeDecoder().decode(StoreEnvelopeV3.self, from: data)
        sessions = try current.sessions.map { try $0.workSession }
        requiresRewrite = false
      default:
        throw SessionStoreCodecError.unsupportedSchemaVersion(probe.schemaVersion)
      }
      try validate(sessions)
    } catch let error as SessionStoreCodecError {
      throw error
    } catch {
      throw SessionStoreCodecError.invalidStore
    }
    return SessionStoreDecodeResult(sessions: sessions, requiresRewrite: requiresRewrite)
  }

  private func validate(_ sessions: [WorkSession]) throws {
    guard Set(sessions.map(\.id)).count == sessions.count else {
      throw SessionStoreCodecError.invalidStore
    }
    do {
      try sessions.forEach { try $0.validate() }
    } catch {
      throw SessionStoreCodecError.invalidStore
    }
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      try container.encode(formatter.string(from: date))
    }
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractionalFormatter.date(from: value) {
        return date
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid ISO 8601 date"
        )
      }
      return date
    }
    return decoder
  }
}

private struct StoreVersionProbe: Decodable {
  let schemaVersion: Int
}

private struct StoreEnvelopeV3: Codable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV3]
}

private struct StoredSessionV3: Codable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV3]
  /// Absent for a session migrated from v2: it was never given a branch of its own.
  let slug: String?
  let notes: String?
  let template: StoredTemplateV2?

  init(_ session: WorkSession) {
    id = session.id.rawValue
    name = session.name
    initialPrompt = session.initialPrompt
    agent = session.agent.map(StoredAgentV2.init)
    appearance = StoredAppearanceV2(session.appearance)
    lifecycle = StoredLifecycleV2(session.lifecycle)
    repositories = session.repositories.map(StoredRepositoryV3.init)
    slug = session.slug?.rawValue
    notes = session.notes
    template = session.template.map(StoredTemplateV2.init)
  }

  var workSession: WorkSession {
    get throws {
      // A slug is a branch name: one edited by hand into something Git would refuse is a store
      // that cannot be trusted, not a value to pass to `git worktree add`.
      let slug = try slug.map { raw in
        guard let slug = SessionSlug(raw) else { throw SessionStoreCodecError.invalidStore }
        return slug
      }
      return WorkSession(
        id: SessionID(rawValue: id),
        name: name,
        initialPrompt: initialPrompt,
        agent: agent?.domainValue,
        appearance: appearance.domainValue,
        status: lifecycle.status,
        createdAt: lifecycle.createdAt,
        updatedAt: lifecycle.updatedAt,
        closedAt: lifecycle.closedAt,
        archivedAt: lifecycle.archivedAt,
        startedAt: lifecycle.startedAt,
        repositories: repositories.map(\.domainValue),
        slug: slug,
        notes: notes,
        template: template?.domainValue
      )
    }
  }
}

private struct StoredRepositoryV3: Codable {
  let id: UUID
  let rootPath: String
  let mode: RepositoryAttachmentMode
  let worktreePath: String?
  let branchName: String?
  let baseRevision: String?
  let createdByVibeManager: Bool
  let attachedAt: Date?
  let failure: StoredRepositoryFailureV3?
  /// Absent until an agent has run for the session.
  let baseline: StoredReferenceSnapshotV3?
  let git: StoredGitSnapshotV2?

  init(_ repository: RepositoryContext) {
    id = repository.id.rawValue
    rootPath = repository.rootPath
    mode = repository.mode
    worktreePath = repository.worktreePath
    branchName = repository.branchName
    baseRevision = repository.baseRevision
    createdByVibeManager = repository.createdByVibeManager
    attachedAt = repository.attachedAt
    failure = repository.failure.map(StoredRepositoryFailureV3.init)
    baseline = repository.baseline.map(StoredReferenceSnapshotV3.init)
    git = repository.git.map(StoredGitSnapshotV2.init)
  }

  var domainValue: RepositoryContext {
    RepositoryContext(
      id: RepositoryID(rawValue: id),
      rootPath: rootPath,
      mode: mode,
      worktreePath: worktreePath,
      branchName: branchName,
      baseRevision: baseRevision,
      createdByVibeManager: createdByVibeManager,
      attachedAt: attachedAt,
      failure: failure?.domainValue,
      baseline: baseline?.domainValue,
      git: git?.domainValue
    )
  }
}

private struct StoredReferenceSnapshotV3: Codable {
  let checkedOutBranch: String?
  let headRevision: String?
  let branches: [String: String]
  let isDirty: Bool
  let capturedAt: Date

  init(_ snapshot: GitReferenceSnapshot) {
    checkedOutBranch = snapshot.checkedOutBranch
    headRevision = snapshot.headRevision
    branches = snapshot.branches
    isDirty = snapshot.isDirty
    capturedAt = snapshot.capturedAt
  }

  var domainValue: GitReferenceSnapshot {
    GitReferenceSnapshot(
      checkedOutBranch: checkedOutBranch,
      headRevision: headRevision,
      branches: branches,
      isDirty: isDirty,
      capturedAt: capturedAt
    )
  }
}

private struct StoredRepositoryFailureV3: Codable {
  let message: String
  let remedy: String

  init(_ failure: RepositoryPreparationFailure) {
    message = failure.message
    remedy = failure.remedy
  }

  var domainValue: RepositoryPreparationFailure {
    RepositoryPreparationFailure(message: message, remedy: remedy)
  }
}

/// The schema v2 document, kept only to be read. Its sessions had one shape of repository: a
/// path and a snapshot.
private struct StoreEnvelopeV2: Decodable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV2]
}

private struct StoredSessionV2: Decodable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV2]
  let notes: String?
  let template: StoredTemplateV2?

  var workSession: WorkSession {
    WorkSession(
      id: SessionID(rawValue: id),
      name: name,
      initialPrompt: initialPrompt,
      agent: agent?.domainValue,
      appearance: appearance.domainValue,
      status: lifecycle.status,
      createdAt: lifecycle.createdAt,
      updatedAt: lifecycle.updatedAt,
      closedAt: lifecycle.closedAt,
      archivedAt: lifecycle.archivedAt,
      startedAt: lifecycle.startedAt,
      repositories: repositories.map(\.domainValue),
      notes: notes,
      template: template?.domainValue
    )
  }
}

private struct StoredAgentV2: Codable {
  let providerID: String
  let modelID: String?
  let resumeIdentifier: String?

  init(_ agent: SessionAgentConfiguration) {
    providerID = agent.providerID
    modelID = agent.modelID
    resumeIdentifier = agent.resumeIdentifier
  }

  var domainValue: SessionAgentConfiguration {
    SessionAgentConfiguration(
      providerID: providerID,
      modelID: modelID,
      resumeIdentifier: resumeIdentifier
    )
  }
}

/// The schema v1 document, kept only to be read.
///
/// Every part of a session but its agent block is unchanged, so only that block has a v1 shape:
/// v1 required a model identifier where v2 makes it optional.
private struct StoreEnvelopeV1: Decodable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV1]
}

private struct StoredSessionV1: Decodable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV1?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV2]
  let notes: String?
  let template: StoredTemplateV2?

  var workSession: WorkSession {
    WorkSession(
      id: SessionID(rawValue: id),
      name: name,
      initialPrompt: initialPrompt,
      agent: agent?.domainValue,
      appearance: appearance.domainValue,
      status: lifecycle.status,
      createdAt: lifecycle.createdAt,
      updatedAt: lifecycle.updatedAt,
      closedAt: lifecycle.closedAt,
      archivedAt: lifecycle.archivedAt,
      startedAt: lifecycle.startedAt,
      repositories: repositories.map(\.domainValue),
      notes: notes,
      template: template?.domainValue
    )
  }
}

private struct StoredAgentV1: Decodable {
  let providerID: String
  let modelID: String
  let resumeIdentifier: String?

  var domainValue: SessionAgentConfiguration {
    // A v1 document could not mean "no model" — the field was required — but an empty string
    // written by hand must not come back as a model name and end up after `--model`.
    SessionAgentConfiguration(
      providerID: providerID,
      modelID: modelID.isEmpty ? nil : modelID,
      resumeIdentifier: resumeIdentifier
    )
  }
}

private struct StoredAppearanceV2: Codable {
  let symbolName: String
  let colorHex: String

  init(_ appearance: SessionAppearance) {
    symbolName = appearance.symbolName
    colorHex = appearance.colorHex
  }

  var domainValue: SessionAppearance {
    SessionAppearance(symbolName: symbolName, colorHex: colorHex)
  }
}

private struct StoredLifecycleV2: Codable {
  let status: SessionStatus
  let createdAt: Date
  let updatedAt: Date
  let closedAt: Date?
  let archivedAt: Date?
  /// Absent from every document written before it was kept, and from the v0 and v1 shapes.
  /// `SessionLifecycle` infers it in that case rather than reading those sessions as never
  /// started.
  let startedAt: Date?

  init(_ lifecycle: SessionLifecycle) {
    status = lifecycle.status
    createdAt = lifecycle.createdAt
    updatedAt = lifecycle.updatedAt
    closedAt = lifecycle.closedAt
    archivedAt = lifecycle.archivedAt
    startedAt = lifecycle.startedAt
  }
}

private struct StoredRepositoryV2: Decodable {
  let id: UUID
  let path: String
  let git: StoredGitSnapshotV2?

  var domainValue: RepositoryContext {
    RepositoryContext(
      id: RepositoryID(rawValue: id),
      rootPath: path,
      mode: .inPlace,
      git: git?.domainValue
    )
  }
}

private struct StoredGitSnapshotV2: Codable {
  let repositoryRootPath: String
  let worktreePath: String?
  let branchName: String?
  let headRevision: String?
  let isDirty: Bool
  let capturedAt: Date

  init(_ snapshot: GitSnapshot) {
    repositoryRootPath = snapshot.repositoryRootPath
    worktreePath = snapshot.worktreePath
    branchName = snapshot.branchName
    headRevision = snapshot.headRevision
    isDirty = snapshot.isDirty
    capturedAt = snapshot.capturedAt
  }

  var domainValue: GitSnapshot {
    GitSnapshot(
      repositoryRootPath: repositoryRootPath,
      worktreePath: worktreePath,
      branchName: branchName,
      headRevision: headRevision,
      isDirty: isDirty,
      capturedAt: capturedAt
    )
  }
}

private struct StoredTemplateV2: Codable {
  let id: String
  let name: String
  let revision: String?

  init(_ template: PromptTemplateReference) {
    id = template.id
    name = template.name
    revision = template.revision
  }

  var domainValue: PromptTemplateReference {
    PromptTemplateReference(id: id, name: name, revision: revision)
  }
}

private struct StoreEnvelopeV0: Decodable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV0]
}

private struct StoredSessionV0: Decodable {
  let id: UUID
  let name: String
  let status: SessionStatus
  let createdAt: Date
  let updatedAt: Date

  var workSession: WorkSession {
    let transitionDate = status == .active ? nil : updatedAt
    return WorkSession(
      id: SessionID(rawValue: id),
      name: name,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
      closedAt: transitionDate,
      archivedAt: status == .archived ? updatedAt : nil
    )
  }
}
