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

  public init(id: String, title: String, agent: String, state: CompanionSessionState) {
    self.id = id
    self.title = title
    self.agent = agent
    self.state = state
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

  public init(
    installationID: String, name: String, version: String, buildLabel: String, online: Bool,
    lastSeen: Date
  ) {
    self.installationID = installationID
    self.name = name
    self.version = version
    self.buildLabel = buildLabel
    self.online = online
    self.lastSeen = lastSeen
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

/// The test the phone sends: its Mac answers with an alert and a `CompanionPong`.
public struct CompanionPing: Hashable, Codable, Sendable {
  public let nonce: String
  public let deviceName: String
  /// The phone's clock.
  public let sentAt: Date

  public init(nonce: String, deviceName: String, sentAt: Date) {
    self.nonce = nonce
    self.deviceName = deviceName
    self.sentAt = sentAt
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

/// Any record of the companion's zone.
public enum CompanionRecord: Hashable, Codable, Sendable {
  case mac(CompanionMac)
  case session(CompanionSession)
  case ping(CompanionPing)
  case pong(CompanionPong)

  /// Unique in the zone whatever the type, hence the prefix: a ping and its pong share a nonce.
  public var recordName: String {
    switch self {
    case .mac(let mac): CompanionRecordName.mac(mac.installationID)
    case .session(let session): CompanionRecordName.session(session.id)
    case .ping(let ping): CompanionRecordName.ping(ping.nonce)
    case .pong(let pong): CompanionRecordName.pong(pong.nonce)
    }
  }
}

/// The names of the records, one prefix per type.
public enum CompanionRecordName {
  public static func mac(_ installationID: String) -> String { "mac-\(installationID)" }
  public static func session(_ id: String) -> String { "session-\(id)" }
  public static func ping(_ nonce: String) -> String { "ping-\(nonce)" }
  public static func pong(_ nonce: String) -> String { "pong-\(nonce)" }
}
