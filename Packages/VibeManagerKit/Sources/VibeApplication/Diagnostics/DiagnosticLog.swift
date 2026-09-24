import Foundation
import VibeDomain

/// Where diagnostic events go.
///
/// Recording never throws, never blocks and never fails the action it describes: a full disk
/// loses the line, not the session.
public protocol DiagnosticLog: Sendable {
  func record(_ event: DiagnosticEvent)
  /// Waits for what was recorded to be written: before the process exits, or an export reads it.
  func flush()
}

extension DiagnosticLog {
  public func flush() {}

  public func record(
    _ category: DiagnosticCategory,
    _ level: DiagnosticLevel,
    _ name: StaticString,
    _ fields: KeyValuePairs<StaticString, DiagnosticValue> = [:]
  ) {
    record(DiagnosticEvent(category, level, name, fields))
  }
}

/// Records nothing: the default of every component, so that a test that does not look at the log
/// does not have to provide one.
public struct NullDiagnosticLog: DiagnosticLog {
  public init() {}
  public func record(_ event: DiagnosticEvent) {}
}

/// Hands every event to each of `logs`.
public struct FanOutDiagnosticLog: DiagnosticLog {
  private let logs: [any DiagnosticLog]

  public init(_ logs: [any DiagnosticLog]) {
    self.logs = logs
  }

  public func record(_ event: DiagnosticEvent) {
    for log in logs { log.record(event) }
  }

  public func flush() {
    for log in logs { log.flush() }
  }
}

/// Keeps every event, for tests.
public final class RecordingDiagnosticLog: DiagnosticLog, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [DiagnosticEvent] = []

  public init() {}

  public func record(_ event: DiagnosticEvent) {
    lock.withLock { recorded.append(event) }
  }

  public var events: [DiagnosticEvent] { lock.withLock { recorded } }

  public var names: [String] { events.map(\.nameText) }

  public func events(named name: String) -> [DiagnosticEvent] {
    events.filter { $0.nameText == name }
  }
}

/// Turns session identifiers into pseudonyms with the salt of this Mac.
public struct SessionPseudonymizer: Sendable {
  private let salt: Data

  public init(salt: Data) {
    self.salt = salt
  }

  /// A salt of its own, for a component nobody gave one: its pseudonyms match no log.
  public static func ephemeral() -> SessionPseudonymizer {
    SessionPseudonymizer(salt: Data(UUID().uuidString.utf8))
  }

  public func callAsFunction(_ id: SessionID) -> DiagnosticValue {
    .session(SessionPseudonym(id, salt: salt))
  }
}

/// A diagnostic log and the pseudonymizer that goes with it: what a component is given.
public struct Diagnostics: Sendable {
  public let log: any DiagnosticLog
  public let pseudonym: SessionPseudonymizer

  public init(log: any DiagnosticLog, pseudonym: SessionPseudonymizer) {
    self.log = log
    self.pseudonym = pseudonym
  }

  public static let disabled = Diagnostics(
    log: NullDiagnosticLog(), pseudonym: SessionPseudonymizer.ephemeral())

  public func record(
    _ category: DiagnosticCategory,
    _ level: DiagnosticLevel,
    _ name: StaticString,
    _ fields: KeyValuePairs<StaticString, DiagnosticValue> = [:]
  ) {
    log.record(DiagnosticEvent(category, level, name, fields))
  }

  public func flush() {
    log.flush()
  }
}

/// Writes an event as one line of JSON. Shared by the file log and the tests that read it back.
public enum DiagnosticLine {
  public static func encode(_ event: DiagnosticEvent, origin: DiagnosticOrigin) -> Data {
    var fields: [String: Any] = [:]
    for field in event.fields {
      fields[field.name.description] = field.value.jsonValue
    }
    let object: [String: Any] = [
      "at": timestamp(event.at),
      "process": origin.rawValue,
      "category": event.category.rawValue,
      "level": event.level.name,
      "name": event.nameText,
      "fields": fields,
    ]
    var data =
      (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    data.append(0x0A)
    return data
  }

  /// The fields, as one short text, for `os_log`.
  public static func summary(_ event: DiagnosticEvent) -> String {
    event.fields.map { "\($0.name)=\($0.value.jsonValue)" }.joined(separator: " ")
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
