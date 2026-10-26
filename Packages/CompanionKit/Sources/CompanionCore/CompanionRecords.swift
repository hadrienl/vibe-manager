import Foundation

/// Where an agent of the Mac stands, as the companion shows it (#347). Three words, read from the
/// application's own `AgentActivity` and never recomputed for the phone.
public enum CompanionSessionState: String, Codable, Hashable, Sendable, CaseIterable {
  /// Waiting for an instruction.
  case waiting
  /// Generating, running a tool.
  case working
  /// Stopped until the user answers a question or a permission.
  case needsAttention
}

/// One active session of the Mac, as the application hands it to its companion agent.
public struct CompanionSessionInfo: Hashable, Codable, Sendable {
  /// The session's UUID, which names its record.
  public let id: String
  public let title: String
  public let agent: String
  public let state: CompanionSessionState
  /// What the agent waits for, while it does (#401): for the request's notification, never for the
  /// session's record.
  public let request: CompanionRequestDetail?

  public init(
    id: String, title: String, agent: String, state: CompanionSessionState,
    request: CompanionRequestDetail? = nil
  ) {
    self.id = id
    self.title = title
    self.agent = agent
    self.state = state
    self.request = request
  }

  /// The session as its record holds it: without the request.
  public var listed: CompanionSessionInfo {
    CompanionSessionInfo(id: id, title: title, agent: agent, state: state)
  }
}

/// What an agent waits for, as its notification says it (#401): a permission and its command, or a
/// question.
public struct CompanionRequestDetail: Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case permission, question
  }

  /// The Mac's key for the request, which an answer names.
  public let requestID: String
  public let kind: Kind
  /// Why the agent asks a permission, or its question; empty when it says nothing.
  public let title: String
  /// The command, the file, the URL a permission is for.
  public let subject: String?

  public init(requestID: String, kind: Kind, title: String, subject: String? = nil) {
    self.requestID = requestID
    self.kind = kind
    self.title = title
    self.subject = subject
  }
}

/// A Mac that publishes, one per installation: an isolated copy of the application is another one,
/// on the same iCloud account.
public struct CompanionMac: Hashable, Codable, Sendable {
  public let installationID: String
  public var name: String
  public var version: String
  /// What tells a test build from another: "#347 abc1234". Empty for a plain build.
  public var buildLabel: String
  /// Written `true` at start, `false` on a clean stop. A crash writes nothing: `lastSeen` says it.
  public var online: Bool
  public var lastSeen: Date
  /// The companion agent's iroh endpoint (#368): its public key, stable from one launch to the
  /// next, which the phone dials for the active channel. `nil` until the endpoint is up.
  public var irohEndpointID: String?
  /// The iroh relay the endpoint calls home: where the phone first finds it, before any hole is
  /// punched.
  public var irohRelayURL: String?

  public init(
    installationID: String, name: String, version: String, buildLabel: String, online: Bool,
    lastSeen: Date, irohEndpointID: String? = nil, irohRelayURL: String? = nil
  ) {
    self.installationID = installationID
    self.name = name
    self.version = version
    self.buildLabel = buildLabel
    self.online = online
    self.lastSeen = lastSeen
    self.irohEndpointID = irohEndpointID
    self.irohRelayURL = irohRelayURL
  }
}

/// An active session of a Mac, as its record holds it.
public struct CompanionSession: Hashable, Codable, Sendable {
  public let id: String
  public let macID: String
  public var title: String
  public var agent: String
  public var state: CompanionSessionState
  /// When the Mac last wrote something new about it.
  public var updatedAt: Date

  public init(
    id: String, macID: String, title: String, agent: String, state: CompanionSessionState,
    updatedAt: Date
  ) {
    self.id = id
    self.macID = macID
    self.title = title
    self.agent = agent
    self.state = state
    self.updatedAt = updatedAt
  }

  public var info: CompanionSessionInfo {
    CompanionSessionInfo(id: id, title: title, agent: agent, state: state)
  }
}

/// The test the phone sends: its Mac answers with an alert and a `CompanionPong` — or, with a
/// `requestDelay`, with a `CompanionRequest` that much later, and nothing else (#368).
public struct CompanionPing: Hashable, Codable, Sendable {
  public let nonce: String
  public let deviceName: String
  /// The phone's clock.
  public let sentAt: Date
  /// A test of the notifications rather than of the synchronisation: the Mac writes a request this
  /// long after `sentAt`, which leaves the user time to lock the phone. `nil` for the plain test.
  public let requestDelay: TimeInterval?

  public init(nonce: String, deviceName: String, sentAt: Date, requestDelay: TimeInterval? = nil) {
    self.nonce = nonce
    self.deviceName = deviceName
    self.sentAt = sentAt
    self.requestDelay = requestDelay
  }
}

/// A Mac's acknowledgement of a test, written as soon as the application has it — not once its
/// alert is dismissed: it measures the synchronisation, not the user.
public struct CompanionPong: Hashable, Codable, Sendable {
  public let nonce: String
  public let macID: String
  /// The Mac's clock.
  public let receivedAt: Date

  public init(nonce: String, macID: String, receivedAt: Date) {
    self.nonce = nonce
    self.macID = macID
    self.receivedAt = receivedAt
  }
}

/// An agent of the Mac that waits for the user — a permission, a question (#368): one record per
/// entry into `needsAttention`, which the phone's subscription turns into a visible notification.
///
/// Its texts are encrypted like the session's: CloudKit pushes a generic alert, and the phone's
/// notification service extension fetches the record to write them in it.
public struct CompanionRequest: Hashable, Codable, Sendable {
  /// Unique to each entry into waiting: a new record, so a new notification, every time.
  public let id: String
  public let macID: String
  public let sessionTitle: String
  public let agent: String
  /// What the agent waits for, said after its name: "attend votre réponse".
  public let text: String
  /// The Mac's clock.
  public let createdAt: Date
  /// The session that waits, and what for (#401): `nil` in a request of an earlier version, and in
  /// the trials' test.
  public let sessionID: String?
  public let detail: CompanionRequestDetail?

  public init(
    id: String, macID: String, sessionTitle: String, agent: String, text: String, createdAt: Date,
    sessionID: String? = nil, detail: CompanionRequestDetail? = nil
  ) {
    self.id = id
    self.macID = macID
    self.sessionTitle = sessionTitle
    self.agent = agent
    self.text = text
    self.createdAt = createdAt
    self.sessionID = sessionID
    self.detail = detail
  }
}

/// The user's answer to a permission, from its notification (#401): the phone writes it in the
/// private database, the Mac that asked hands it to the application, then deletes it.
public struct CompanionAnswer: Hashable, Codable, Sendable {
  public enum Choice: String, Codable, Hashable, Sendable {
    case allowOnce, deny
  }

  public let id: String
  public let macID: String
  public let sessionID: String
  public let requestID: String
  public let choice: Choice
  /// The phone's clock.
  public let createdAt: Date

  public init(
    id: String, macID: String, sessionID: String, requestID: String, choice: Choice,
    createdAt: Date
  ) {
    self.id = id
    self.macID = macID
    self.sessionID = sessionID
    self.requestID = requestID
    self.choice = choice
    self.createdAt = createdAt
  }
}

/// A phone of the user's, admitted to the direct channel (#398, #399): it writes this record with
/// its iroh endpoint — its public key — in the user's private database, where nobody else can
/// write, and the Mac takes connections from those endpoints alone.
public struct CompanionDevice: Hashable, Codable, Sendable {
  public let endpointID: String
  public var name: String
  public var addedAt: Date

  public init(endpointID: String, name: String, addedAt: Date) {
    self.endpointID = endpointID
    self.name = name
    self.addedAt = addedAt
  }
}

/// Who may use the direct channel (#398): a phone whose endpoint the user's private database lists,
/// and nobody else — whatever it knows of the Mac's address.
public enum CompanionAdmission {
  public static func admits(_ endpointID: String, among records: [CompanionRecord]) -> Bool {
    !endpointID.isEmpty
      && records.contains {
        if case .device(let device) = $0 { return device.endpointID == endpointID }
        return false
      }
  }
}

/// Any record of the companion's zone.
public enum CompanionRecord: Hashable, Codable, Sendable {
  case mac(CompanionMac)
  case session(CompanionSession)
  case ping(CompanionPing)
  case pong(CompanionPong)
  case request(CompanionRequest)
  case device(CompanionDevice)
  case answer(CompanionAnswer)

  /// Unique in the zone whatever the type, hence the prefix: a ping and its pong share a nonce.
  public var recordName: String {
    switch self {
    case .mac(let mac): CompanionRecordName.mac(mac.installationID)
    case .session(let session): CompanionRecordName.session(session.id)
    case .ping(let ping): CompanionRecordName.ping(ping.nonce)
    case .pong(let pong): CompanionRecordName.pong(pong.nonce)
    case .request(let request): CompanionRecordName.request(request.id)
    case .device(let device): CompanionRecordName.device(device.endpointID)
    case .answer(let answer): CompanionRecordName.answer(answer.id)
    }
  }
}

/// The names of the records, one prefix per type.
public enum CompanionRecordName {
  public static func mac(_ installationID: String) -> String { "mac-\(installationID)" }
  public static func session(_ id: String) -> String { "session-\(id)" }
  public static func ping(_ nonce: String) -> String { "ping-\(nonce)" }
  public static func pong(_ nonce: String) -> String { "pong-\(nonce)" }
  public static func request(_ id: String) -> String { "request-\(id)" }
  public static func device(_ endpointID: String) -> String { "device-\(endpointID)" }
  public static func answer(_ id: String) -> String { "answer-\(id)" }
}
