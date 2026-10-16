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
  /// the same reason: an older build would erase them. v7 adds the project icon of a session's
  /// appearance (#27), again for that reason. v8 adds each session's place in the order arranged
  /// by hand (#44), v9 the conversation theme chosen for a session (#274), and v10 whether a
  /// session coordinates others or is one of their children (#352). Each shape is the one before
  /// with one more optional field, so all seven are read by the same structure.
  static let currentSchemaVersion = 10
  /// v9 is v10 without coordination: every session is an ordinary one.
  static let uncoordinatedSchemaVersion = 9
  /// v8 is v9 without the themes: every session follows the settings.
  static let themelessSchemaVersion = 8
  /// v7 is v8 without the ranks: the sessions are ranked in the order the store lists them.
  static let ranklessSchemaVersion = 7
  /// v6 is v7 without the project icon: the session wears the symbol and the colour it had.
  static let iconlessSchemaVersion = 6
  /// v5 is v6 without the task status, which is read from the lifecycle instead.
  static let statuslessSchemaVersion = 5
  static let ticketlessSchemaVersion = 4
  static let previousSchemaVersion = 2
  /// Written only by a build of #12 that created a worktree per session, and was reworked before
  /// release. Read back so that the sessions it migrated are not lost; it is never written again.
  static let abandonedSchemaVersion = 3

  func encode(sessions: [WorkSession], savedAt: Date = Date()) throws -> Data {
    try validate(sessions)
    let envelope = StoreEnvelopeV9(
      schemaVersion: Self.currentSchemaVersion,
      savedAt: savedAt,
      sessions: sessions.map(StoredSessionV9.init)
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

    var sessions: [WorkSession]
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
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV9.self, from: data)
        sessions = previous.sessions.map { $0.workSession(recordsStart: false) }
        requiresRewrite = true
      case Self.iconlessSchemaVersion, Self.ranklessSchemaVersion, Self.themelessSchemaVersion,
        Self.uncoordinatedSchemaVersion:
        let previous = try Self.makeDecoder().decode(StoreEnvelopeV9.self, from: data)
        sessions = previous.sessions.map { $0.workSession(recordsStart: true) }
        requiresRewrite = true
      case Self.currentSchemaVersion:
        let current = try Self.makeDecoder().decode(StoreEnvelopeV9.self, from: data)
        sessions = current.sessions.map { $0.workSession(recordsStart: true) }
        requiresRewrite = false
      case Self.abandonedSchemaVersion:
        let abandoned = try Self.makeDecoder().decode(StoreEnvelopeV3.self, from: data)
        sessions = abandoned.sessions.map(\.workSession)
        requiresRewrite = true
      default:
        throw SessionStoreCodecError.unsupportedSchemaVersion(probe.schemaVersion)
      }
      if probe.schemaVersion < Self.themelessSchemaVersion {
        sessions = Self.rankedByActivity(sessions)
      }
      try validate(sessions)
    } catch let error as SessionStoreCodecError {
      throw error
    } catch {
      throw SessionStoreCodecError.invalidStore
    }
    return SessionStoreDecodeResult(sessions: sessions, requiresRewrite: requiresRewrite)
  }

  /// The order a store written before #44 is given: the one it was listed in, last activity
  /// first. Choosing Manual in the sort menu at the first launch then moves nothing.
  static func rankedByActivity(_ sessions: [WorkSession]) -> [WorkSession] {
    sessions
      .sorted {
        $0.updatedAt != $1.updatedAt
          ? $0.updatedAt > $1.updatedAt : $0.id.description < $1.id.description
      }
      .enumerated()
      .map { index, session in
        var ranked = session
        ranked.rank = index
        return ranked
      }
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
      try container.encode(StoreDates.format(date))
    }
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = StoreDates.parse(value) else {
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

/// The store's dates, read and written by formatters made once. Making two per date cost a
/// quarter of a second per read of a store of two hundred sessions — and the store is read every
/// few seconds by each conversation followed, which kept its actor busy enough to hold a launch
/// waiting on it for twenty seconds.
///
/// Even made once, a formatter still takes 0.2 to 0.7 ms per date on macOS 27: nearly a second
/// for a store of two hundred sessions (#253). The one shape the store writes is therefore read
/// by arithmetic, and the formatters only read the others: older documents, or edited by hand.
enum StoreDates {
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
  private static let lock = NSLock()

  static func parse(_ text: String) -> Date? {
    utcMilliseconds(text)
      ?? lock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
  }

  /// `yyyy-MM-ddTHH:mm:ss.SSSZ`, the shape `format` writes, or nil for anything else.
  ///
  /// `Double(seconds) + Double(milliseconds) / 1000` since 1970 gives the very value the
  /// formatter gives, bit for bit; counting from 2001 or multiplying by 0.001 does not.
  static func utcMilliseconds(_ text: String) -> Date? {
    var text = text
    return text.withUTF8 { bytes -> Date? in
      guard bytes.count == 24, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
        bytes[13] == 0x3A, bytes[16] == 0x3A, bytes[19] == 0x2E, bytes[23] == 0x5A
      else { return nil }
      func number(_ start: Int, _ count: Int) -> Int? {
        var value = 0
        for index in start..<(start + count) {
          let digit = Int(bytes[index]) - 0x30
          guard (0...9).contains(digit) else { return nil }
          value = value * 10 + digit
        }
        return value
      }
      guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
        let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
        let millisecond = number(20, 3),
        year >= 1970, (1...12).contains(month), (1...daysIn(month, of: year)).contains(day),
        hour < 24, minute < 60, second < 60
      else { return nil }
      let seconds =
        daysFromCivil(year: year, month: month, day: day) * 86_400
        + hour * 3_600 + minute * 60 + second
      return Date(timeIntervalSince1970: Double(seconds) + Double(millisecond) / 1_000)
    }
  }

  /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let year = month <= 2 ? year - 1 : year
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func daysIn(_ month: Int, of year: Int) -> Int {
    switch month {
    case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  static func format(_ date: Date) -> String {
    lock.withLock { fractional.string(from: date) }
  }
}

private struct StoreVersionProbe: Decodable {
  let schemaVersion: Int
}

/// Reads v4 to v9 as well: a v9 session is a v10 one without coordination, a v8 one has no theme, a v7 one has no rank either,
/// a v6 one no icon, a v5 one no `taskStatus`, and a v4 one no `ticket`.
private struct StoreEnvelopeV9: Codable {
  let schemaVersion: Int
  let savedAt: Date
  let sessions: [StoredSessionV9]
}

/// A v2 session, the history of its agent switches (v4), its ticket (v5), its task status (v6) and
/// its project icon (v7), its rank (v8), its conversation theme (v9) and its part in a coordination
/// (v10).
private struct StoredSessionV9: Codable {
  let id: UUID
  let name: String
  let initialPrompt: String
  let agent: StoredAgentV2?
  let appearance: StoredAppearanceV7
  let lifecycle: StoredLifecycleV2
  let repositories: [StoredRepositoryV2]
  let notes: String?
  let template: StoredTemplateV2?
  let agentHistory: [StoredAgentChangeV4]?
  let ticket: StoredTicketV5?
  /// Spelled out rather than decoded as the enum: a status written by a later build is read from
  /// the lifecycle, as if it had never been written, instead of taking the whole store down.
  let taskStatus: String?
  /// Absent before v8, where the codec ranks the sessions itself.
  let rank: Int?
  /// Absent before v9, and for a session that follows the settings.
  let conversationTheme: String?
  /// Absent before v10, and for an ordinary session.
  let coordination: StoredCoordinationV10?

  init(_ session: WorkSession) {
    id = session.id.rawValue
    name = session.name
    initialPrompt = session.initialPrompt
    agent = session.agent.map(StoredAgentV2.init)
    appearance = StoredAppearanceV7(session.appearance)
    lifecycle = StoredLifecycleV2(session.lifecycle)
    repositories = session.repositories.map(StoredRepositoryV2.init)
    notes = session.legacyNotes
    template = session.template.map(StoredTemplateV2.init)
    agentHistory = session.agentHistory.map(StoredAgentChangeV4.init)
    ticket = session.ticket.map(StoredTicketV5.init)
    taskStatus = session.taskStatus.rawValue
    rank = session.rank
    conversationTheme = session.conversationTheme
    coordination = session.coordination.map(StoredCoordinationV10.init)
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
      rank: rank ?? 0,
      // An empty one, which no build writes, follows the settings rather than failing the store.
      conversationTheme: conversationTheme.flatMap { $0.isEmpty ? nil : $0 },
      coordination: coordination?.domainValue(for: id),
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

/// A session's part in a coordination, field by field: a role written by a later build, or a child
/// said to be its own, reads as an ordinary session rather than as a store that cannot be opened.
private struct StoredCoordinationV10: Codable {
  let role: String
  let coordinator: UUID?

  init(_ coordination: SessionCoordination) {
    switch coordination {
    case .coordinator:
      role = "coordinator"
      coordinator = nil
    case .child(let id):
      role = "child"
      coordinator = id.rawValue
    }
  }

  func domainValue(for session: UUID) -> SessionCoordination? {
    switch role {
    case "coordinator":
      return .coordinator
    case "child":
      guard let coordinator, coordinator != session else { return nil }
      return .child(of: SessionID(rawValue: coordinator))
    default:
      return nil
    }
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
  /// The CLI that ran an endpoint's conversation (#107). Absent from every document written
  /// before, and from every conversation that is not an endpoint's.
  let harnessID: String?

  init(_ agent: SessionAgentConfiguration) {
    providerID = agent.providerID
    modelID = agent.modelID
    resumeIdentifier = agent.resumeIdentifier
    harnessID = agent.harnessID
  }

  var domainValue: SessionAgentConfiguration {
    SessionAgentConfiguration(
      providerID: providerID,
      modelID: modelID,
      resumeIdentifier: resumeIdentifier,
      harnessID: harnessID
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

/// The v2 appearance and the project icon, which a value that is not a digest cannot name: such a
/// value is dropped, and the badge falls back on the symbol and the colour.
private struct StoredAppearanceV7: Codable {
  let symbolName: String
  let colorHex: String
  let iconID: String?

  init(_ appearance: SessionAppearance) {
    symbolName = appearance.symbolName
    colorHex = appearance.colorHex
    iconID = appearance.iconID?.sha256
  }

  var domainValue: SessionAppearance {
    SessionAppearance(
      symbolName: symbolName,
      colorHex: colorHex,
      iconID: iconID.flatMap { (value: String) -> SessionIconID? in SessionIconID(sha256: value) }
    )
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
