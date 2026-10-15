import Foundation

/// Whether a Mac is there, read from its record alone (#347).
///
/// CloudKit is not a presence channel: every write is a silent push to the phone, and iOS delays or
/// drops them past two or three an hour. So the Mac writes `lastSeen` every 15 minutes, and the
/// phone allows 20 before it calls the Mac gone. A clean stop says so at once with `online`.
public enum CompanionPresence {
  /// How often the Mac's companion agent writes `lastSeen`.
  public static let heartbeat: TimeInterval = 15 * 60
  /// How old `lastSeen` may be for the Mac to count as connected.
  public static let tolerance: TimeInterval = 20 * 60

  public static func isConnected(_ mac: CompanionMac, now: Date) -> Bool {
    mac.online && now.timeIntervalSince(mac.lastSeen) < tolerance
  }
}

/// What the Mac does with the tests it finds.
public enum CompanionInbox {
  /// A test older than this is not shown any more: deleted, unanswered.
  public static let maximumPingAge: TimeInterval = 10 * 60

  public struct Triage: Equatable, Sendable {
    /// Oldest first, so the alerts come in the order the phone sent them.
    public var toAnswer: [CompanionPing]
    /// The tests of the notifications (#368): the agent answers them alone, with a request, and
    /// the application never sees them.
    public var toNotify: [CompanionPing] = []
    public var expired: [CompanionPing]
  }

  /// The tests to hand the application, the ones the agent answers itself, and the ones to delete.
  /// `handled` holds the nonces already taken, so that the same record fetched twice raises a
  /// single alert.
  public static func triage(_ pings: [CompanionPing], handled: Set<String>, now: Date) -> Triage {
    var triage = Triage(toAnswer: [], expired: [])
    for ping in pings.sorted(by: { $0.sentAt < $1.sentAt }) where !handled.contains(ping.nonce) {
      if now.timeIntervalSince(ping.sentAt) > maximumPingAge {
        triage.expired.append(ping)
      } else if ping.requestDelay != nil {
        triage.toNotify.append(ping)
      } else {
        triage.toAnswer.append(ping)
      }
    }
    return triage
  }
}

/// The requests the Mac writes for the phone to notify (#368).
///
/// A request is a new record each time an agent starts waiting for the user: CloudKit notifies the
/// creation of a record, never its update. They are worth nothing once seen, and deleted after an
/// hour so that the zone does not grow with them.
public enum CompanionRequests {
  public static let maximumAge: TimeInterval = 60 * 60
  /// Said after the agent's name in the notification.
  public static let waitingText = "attend votre réponse"
  /// What the agent of a session without one is called.
  public static let unnamedAgent = "L’agent"

  /// The sessions that started waiting for the user between two snapshots: once per entry, however
  /// many snapshots it lasts. The first snapshot an agent receives is where it starts from, not a
  /// change: an agent already waiting when the application started was there before, and is not
  /// notified again at each launch.
  public static func entered(
    previous: [CompanionSessionInfo]?, current: [CompanionSessionInfo]
  ) -> [CompanionSessionInfo] {
    guard let previous else { return [] }
    let waiting = Set(previous.filter { $0.state == .needsAttention }.map(\.id))
    return current.filter { $0.state == .needsAttention && !waiting.contains($0.id) }
  }

  /// The request for a session that just started waiting.
  public static func request(
    for session: CompanionSessionInfo, macID: String, id: String, now: Date
  ) -> CompanionRequest {
    CompanionRequest(
      id: id, macID: macID, sessionTitle: session.title,
      agent: session.agent.isEmpty ? unnamedAgent : session.agent, text: waitingText,
      createdAt: now)
  }

  /// The names of this Mac's requests past `maximumAge`: another Mac's are its own to delete.
  public static func expired(_ requests: [CompanionRequest], macID: String, now: Date) -> [String] {
    requests.filter { $0.macID == macID && now.timeIntervalSince($0.createdAt) > maximumAge }
      .map { CompanionRecordName.request($0.id) }.sorted()
  }
}

/// What the Mac's companion agent writes when the application hands it a new set of sessions.
public enum CompanionSessionMerge {
  public struct Plan: Equatable, Sendable {
    public var saves: [CompanionSession]
    /// Record names.
    public var deletions: [String]
  }

  /// The sessions of `macID` become exactly `snapshot`: a session that did not change keeps its
  /// record untouched — no write, no push — and one that is no longer active is deleted. The
  /// sessions of other Macs are not this one's to touch.
  public static func plan(
    snapshot: [CompanionSessionInfo], stored: [CompanionSession], macID: String, now: Date
  ) -> Plan {
    let own = Dictionary(
      stored.filter { $0.macID == macID }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    var saves: [CompanionSession] = []
    for info in snapshot {
      if let existing = own[info.id], existing.info == info { continue }
      saves.append(
        CompanionSession(
          id: info.id, macID: macID, title: info.title, agent: info.agent, state: info.state,
          updatedAt: now))
    }
    let kept = Set(snapshot.map(\.id))
    let deletions = own.keys.filter { !kept.contains($0) }.sorted().map(CompanionRecordName.session)
    return Plan(saves: saves, deletions: deletions)
  }
}

/// One press of Test on the phone, from the ping to its acknowledgement.
public struct CompanionTestRun: Hashable, Sendable {
  public enum Stage: Hashable, Sendable {
    /// Written on the phone, not yet in iCloud.
    case sending
    /// In iCloud: the Mac can fetch it.
    case sent
    /// The Mac's pong came back.
    case acknowledged
  }

  public let nonce: String
  /// The phone's clock.
  public let sentAt: Date
  public private(set) var stage: Stage = .sending
  /// When the Mac had it, by the Mac's clock.
  public private(set) var receivedAt: Date?
  /// When the pong reached the phone, by the phone's clock.
  public private(set) var acknowledgedAt: Date?

  public init(nonce: String, sentAt: Date) {
    self.nonce = nonce
    self.sentAt = sentAt
  }

  /// The ping reached iCloud. Never moves an acknowledged test back.
  public mutating func markSent() {
    if stage == .sending { stage = .sent }
  }

  /// Takes the pong when it answers this test.
  ///
  /// - Returns: whether it did.
  @discardableResult
  public mutating func acknowledge(_ pong: CompanionPong, at now: Date) -> Bool {
    guard pong.nonce == nonce, stage != .acknowledged else { return false }
    stage = .acknowledged
    receivedAt = pong.receivedAt
    acknowledgedAt = now
    return true
  }

  /// From the phone to the Mac, across the clocks of both: an estimate, off by their drift.
  public var oneWay: TimeInterval? {
    receivedAt.map { $0.timeIntervalSince(sentAt) }
  }

  /// There and back, on the phone's clock alone.
  public var roundTrip: TimeInterval? {
    acknowledgedAt.map { $0.timeIntervalSince(sentAt) }
  }
}
