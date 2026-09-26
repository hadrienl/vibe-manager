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
  /// v4 adds the history of agent switches (#15). A build that only knows v2 would read such a
  /// document, ignore the history as an unknown key, and erase it at its first write; refusing
  /// the document is louder, and loses nothing.
  ///
  /// v5 adds the ticket a session works on (#69), and v6 each session's task status (#80), for
  /// the same reason: an older build would erase them. Each shape is the one before with one more
  /// optional field, so all three are read by the same structure.
  static let currentSchemaVersion = 6
  /// v5 is v6 without the task status, which is read from the lifecycle instead.
  static let statuslessSchemaVersion = 5
  static let ticketlessSchemaVersion = 4
  static let previousSchemaVersion = 2
  /// Written only by a build of #12 that created a worktree per session, and was reworked before
  /// release. Read back so that the sessions it migrated are not lost; it is never written again.
  static let abandonedSchemaVersion = 3

  func encode(sessions: [WorkSession], savedAt: Date = Date()) throws -> Data {
    try validate(sessions)
    let envelope = StoreEnvelopeV6(
      schemaVersion: Self.currentSchemaVersion,
      savedAt: savedAt,
      sessions: sessions.map(StoredSessionV6.init)
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
      case Self.previousSchemaVersion:
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV2.self, from: data)
        sessions = previous.sessions.map(\.workSession)
        requiresRewrite = true
      case Self.ticketlessSchemaVersion, Self.statuslessSchemaVersion:
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV6.self, from: data)
        sessions = previous.sessions.map { $0.workSession(recordsStart: false) }
        requiresRewrite = true
      case Self.currentSchemaVersion:
        let current = try Self.makeDecoder().decode(StoreEnvelopeV6.self, from: data)
        sessions = current.sessions.map { $0.workSession(recordsStart: true) }
        requiresRewrite = false
      case Self.abandonedSchemaVersion:
        let abandoned = try Self.makeDecoder().decode(StoreEnvelopeV3.self, from: data)
        sessions = abandoned.sessions.map(\.workSession)
        requiresRewrite = true
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

  static func makeEncoder() -> JSONEncoder {
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

  static func makeDecoder() -> JSONDecoder {
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

/// Reads v4 and v5 as well: a v5 session is a v6 one without `taskStatus`, and a v4 one has no
/// `ticket` either.
private struct StoreEnvelopeV6: Codable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV6]
}

/// A v2 session, the history of its agent switches (v4), its ticket (v5) and its task status (v6).
private struct StoredSessionV6: Codable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV2]
  let notes: String?
  let template: StoredTemplateV2?
  let agentHistory: [StoredAgentChangeV4]?
  let ticket: StoredTicketV5?
  /// Spelled out rather than decoded as the enum: a status written by a later build is read from
  /// the lifecycle, as if it had never been written, instead of taking the whole store down.
  let taskStatus: String?

  init(_ session: WorkSession) {
    id = session.id.rawValue
    name = session.name
    initialPrompt = session.initialPrompt
    agent = session.agent.map(StoredAgentV2.init)
    appearance = StoredAppearanceV2(session.appearance)
    lifecycle = StoredLifecycleV2(session.lifecycle)
    repositories = session.repositories.map(StoredRepositoryV2.init)
    notes = session.legacyNotes
    template = session.template.map(StoredTemplateV2.init)
    agentHistory = session.agentHistory.map(StoredAgentChangeV4.init)
    ticket = session.ticket.map(StoredTicketV5.init)
    taskStatus = session.taskStatus.rawValue
  }

  /// - Parameter recordsStart: the document was written by a build that records the start of
  ///   every session (v6). A missing start then means never started, and is not inferred: moving a
  ///   session that never ran between columns touches it, and the inference would read that as a
  ///   run, so that moving it In Progress would restart it instead of starting it with its prompt.
  func workSession(recordsStart: Bool) -> WorkSession {
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
      legacyNotes: notes,
      template: template?.domainValue,
      agentHistory: (agentHistory ?? []).map(\.domainValue),
      ticket: ticket?.domainValue,
      taskStatus: storedTaskStatus,
      infersStartedAt: !recordsStart
    )
  }

  /// A status that contradicts the lifecycle is dropped the same way: archived is the one status
  /// the lifecycle decides, and a store that disagreed would otherwise fail validation whole.
  private var storedTaskStatus: SessionTaskStatus? {
    guard let status = taskStatus.flatMap(SessionTaskStatus.init(rawValue:)) else { return nil }
    return (status == .archived) == (lifecycle.status == .archived) ? status : nil
  }
}

/// A ticket, field by field: a source written by a later build reads as a manual one, and an
/// address that is not one reads as no ticket rather than as a store that cannot be opened.
private struct StoredTicketV5: Codable {
  let url: String?
  let source: String

  init(_ ticket: SessionTicket) {
    url = ticket.url?.absoluteString
    source = ticket.source.rawValue
  }

  var domainValue: SessionTicket? {
    let source = SessionTicket.Source(rawValue: source) ?? .manual
    guard let url else { return SessionTicket(url: nil, source: source) }
    guard let parsed = URL(string: url) else { return nil }
    return SessionTicket(url: parsed, source: source)
  }
}

/// One switch, spelled out field by field rather than through the enums' synthesized coding: a
/// kind written by a later build is read as the closest thing this one knows, instead of taking
/// the whole store down with it.
private struct StoredAgentChangeV4: Codable {
  let id: UUID
  let date: Date
  let previous: StoredAgentV2
  let next: StoredAgentV2
  let handover: String
  let summaryByteCount: Int?
  let summaryIsTruncated: Bool?
  let summaryWasEdited: Bool?
  let outcome: String
  let failureReason: String?

  init(_ change: AgentChange) {
    id = change.id
    date = change.date
    previous = StoredAgentV2(change.previous)
    next = StoredAgentV2(change.next)
    switch change.handover {
    case .resumedConversation:
      handover = "resumedConversation"
      summaryByteCount = nil
      summaryIsTruncated = nil
      summaryWasEdited = nil
    case .summary(let byteCount, let isTruncated, let wasEdited):
      handover = "summary"
      summaryByteCount = byteCount
      summaryIsTruncated = isTruncated
      summaryWasEdited = wasEdited
    case .initialPrompt:
      handover = "initialPrompt"
      summaryByteCount = nil
      summaryIsTruncated = nil
      summaryWasEdited = nil
    case .nothing:
      handover = "nothing"
      summaryByteCount = nil
      summaryIsTruncated = nil
      summaryWasEdited = nil
    }
    switch change.outcome {
    case .completed:
      outcome = "completed"
      failureReason = nil
    case .failed(let reason):
      outcome = "failed"
      failureReason = reason
    }
  }

  var domainValue: AgentChange {
    let handover: AgentChange.Handover
    switch self.handover {
    case "resumedConversation":
      handover = .resumedConversation
    case "initialPrompt":
      handover = .initialPrompt
    case "summary":
      handover = .summary(
        byteCount: summaryByteCount ?? 0,
        isTruncated: summaryIsTruncated ?? false,
        wasEdited: summaryWasEdited ?? false
      )
    default:
      handover = .nothing
    }
    let outcome: AgentChange.Outcome =
      self.outcome == "completed" ? .completed : .failed(reason: failureReason ?? "")
    return AgentChange(
      id: id,
      date: date,
      previous: previous.domainValue,
      next: next.domainValue,
      handover: handover,
      outcome: outcome
    )
  }
}

/// The schema v2 document, kept only to be read: v4 is v2 with the history of agent switches.
private struct StoreEnvelopeV2: Codable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV2]
}

private struct StoredSessionV2: Codable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV2]
  let notes: String?
  let template: StoredTemplateV2?

  init(_ session: WorkSession) {
    id = session.id.rawValue
    name = session.name
    initialPrompt = session.initialPrompt
    agent = session.agent.map(StoredAgentV2.init)
    appearance = StoredAppearanceV2(session.appearance)
    lifecycle = StoredLifecycleV2(session.lifecycle)
    repositories = session.repositories.map(StoredRepositoryV2.init)
    notes = session.legacyNotes
    template = session.template.map(StoredTemplateV2.init)
  }

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
      legacyNotes: notes,
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
      legacyNotes: notes,
      template: template?.domainValue
    )
  }
}

/// The schema v3 document of the abandoned #12 build, kept only to be read.
///
/// It differs from v2 by its repositories alone: `rootPath` and an attachment mode where v2 has a
/// `path`. What the agent was started in is what the session keeps — the worktree, when one was
/// made — so that resuming it finds its conversation again; the rest is dropped.
private struct StoreEnvelopeV3: Decodable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV3]
}

private struct StoredSessionV3: Decodable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV2
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV3]
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
      legacyNotes: notes,
      template: template?.domainValue
    )
  }
}

private struct StoredRepositoryV3: Decodable {
  let id: UUID
  let rootPath: String
  let mode: String?
  let worktreePath: String?

  var domainValue: RepositoryContext {
    let worktree = mode == "worktree" ? worktreePath.flatMap { $0.isEmpty ? nil : $0 } : nil
    return RepositoryContext(id: RepositoryID(rawValue: id), path: worktree ?? rootPath)
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

private struct StoredRepositoryV2: Codable {
  let id: UUID
  let path: String
  let git: StoredGitSnapshotV2?

  init(_ repository: RepositoryContext) {
    id = repository.id.rawValue
    path = repository.path
    git = repository.git.map(StoredGitSnapshotV2.init)
  }

  var domainValue: RepositoryContext {
    RepositoryContext(
      id: RepositoryID(rawValue: id),
      path: path,
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
