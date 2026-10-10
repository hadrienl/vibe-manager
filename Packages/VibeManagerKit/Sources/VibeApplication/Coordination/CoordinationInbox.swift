import Foundation
import VibeDomain

/// Something a coordinator is told about, between two of its turns (#352).
public struct CoordinationEvent: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// The child's agent finished a turn and waits for its next message.
    case turnEnded
    /// The child waits for the user: a permission or a question, as it reads.
    case awaitingUser(String)
    /// The child's agent stopped.
    case stopped
    /// The user moved the child to another column.
    case statusChanged(SessionTaskStatus)
    /// A wake-up the coordinator asked for, with what it wanted to check.
    case wake(String)
  }

  public let childID: SessionID?
  public let childName: String
  public let kind: Kind
  public let date: Date

  public init(childID: SessionID?, childName: String, kind: Kind, date: Date) {
    self.childID = childID
    self.childName = childName
    self.kind = kind
    self.date = date
  }

  public static func wake(_ reason: String, at date: Date) -> Self {
    Self(childID: nil, childName: "", kind: .wake(reason), date: date)
  }

  /// One line of the message, for the agent.
  var line: String {
    let child = childID.map { "“\(childName)” (\($0.rawValue.uuidString))" } ?? ""
    switch kind {
    case .turnEnded:
      return "\(child) finished its turn."
    case .awaitingUser(let what):
      return "\(child) is waiting for the user: \(what). It is the user's to answer."
    case .stopped:
      return "\(child) stopped: its agent is no longer running."
    case .statusChanged(let status):
      return "The user moved \(child) to \(status.rawValue)."
    case .wake(let reason):
      return "Wake-up you asked for: \(reason)"
    }
  }
}

/// What waits to be told to each coordinator, gathered for a few seconds so that a burst — three
/// children finishing together — reaches it as one message, and one turn (#352).
///
/// Pure: the clock is given, and whether a coordinator can be written to is the caller's to say.
public struct CoordinationInbox: Sendable {
  /// How long after the last event a coordinator's events are delivered.
  public static let quietPeriod: TimeInterval = 3
  /// At most this many events in one message; the rest are counted.
  static let shownLimit = 20

  private var pending: [SessionID: [CoordinationEvent]] = [:]

  public init() {}

  public var isEmpty: Bool { pending.isEmpty }

  public func events(for coordinator: SessionID) -> [CoordinationEvent] {
    pending[coordinator] ?? []
  }

  /// Adds an event. The same news about the same child, told twice in a row, is told once.
  public mutating func add(_ event: CoordinationEvent, for coordinator: SessionID) {
    var events = pending[coordinator] ?? []
    if let last = events.last(where: { $0.childID == event.childID && event.childID != nil }),
      last.kind == event.kind
    {
      events.removeAll { $0 == last }
    }
    if case .wake = event.kind {
      events.removeAll { if case .wake = $0.kind { true } else { false } }
    }
    events.append(event)
    pending[coordinator] = events
  }

  /// The coordinators whose last event is older than the quiet period.
  public func due(at now: Date) -> [SessionID] {
    pending.compactMap { id, events in
      guard let last = events.map(\.date).max(),
        now.timeIntervalSince(last) >= Self.quietPeriod
      else { return nil }
      return id
    }
  }

  /// Takes a coordinator's events, which are no longer pending.
  public mutating func take(for coordinator: SessionID) -> [CoordinationEvent] {
    pending.removeValue(forKey: coordinator) ?? []
  }

  /// Forgets a coordinator's events: it is gone, or no longer running.
  public mutating func drop(_ coordinator: SessionID) {
    pending[coordinator] = nil
  }

  /// The message a coordinator is sent: marked as Vibe Manager's, one line per event.
  public static func message(for events: [CoordinationEvent]) -> String {
    let shown = events.prefix(shownLimit)
    var lines = shown.map { "- " + $0.line }
    if events.count > shown.count {
      lines.append("- …and \(events.count - shown.count) more: see sessions_list.")
    }
    let title =
      events.count == 1 ? "[Vibe Manager] 1 event:" : "[Vibe Manager] \(events.count) events:"
    return ([title] + lines).joined(separator: "\n")
  }
}
