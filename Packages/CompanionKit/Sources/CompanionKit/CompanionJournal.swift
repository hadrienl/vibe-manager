import CloudKit
import Foundation

/// One line of the journal.
public struct CompanionJournalEntry: Hashable, Sendable, Identifiable {
  public let id: UUID
  public let date: Date
  public let text: String

  public init(date: Date, text: String, id: UUID = UUID()) {
    self.id = id
    self.date = date
    self.text = text
  }
}

/// The last events of the synchronisation, timestamped, newest first (#347): what the debug screen
/// shows and copies, so that "it does not connect" comes with its reason.
public struct CompanionJournal: Sendable {
  public static let capacity = 100
  public private(set) var entries: [CompanionJournalEntry] = []

  public init() {}

  public mutating func record(_ text: String, at date: Date = Date()) {
    entries.insert(CompanionJournalEntry(date: date, text: text), at: 0)
    if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
  }

  /// The journal as text to copy, one "HH:mm:ss text" a line, newest first.
  public static func text(_ entries: [CompanionJournalEntry], timeZone: TimeZone = .current)
    -> String
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return entries.map { entry in
      let parts = calendar.dateComponents([.hour, .minute, .second], from: entry.date)
      let time = String(
        format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
      return "\(time) \(entry.text)"
    }.joined(separator: "\n")
  }

  /// "1 Mac, 3 Session" — what a batch of records holds, by type, for one line of the journal.
  static func summary(_ types: [String]) -> String {
    var counts: [String: Int] = [:]
    for type in types { counts[type, default: 0] += 1 }
    return counts.keys.sorted().map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", ")
  }
}

/// A CloudKit error said plainly: its code's name and CloudKit's own sentence.
public enum CompanionErrorText {
  public static func describe(_ error: any Error) -> String {
    guard let error = error as? CKError else { return error.localizedDescription }
    return "\(name(of: error.code)) — \(error.localizedDescription)"
  }

  static func name(of code: CKError.Code) -> String {
    switch code {
    case .notAuthenticated: "notAuthenticated"
    case .networkUnavailable: "networkUnavailable"
    case .networkFailure: "networkFailure"
    case .serviceUnavailable: "serviceUnavailable"
    case .requestRateLimited: "requestRateLimited"
    case .zoneBusy: "zoneBusy"
    case .zoneNotFound: "zoneNotFound"
    case .userDeletedZone: "userDeletedZone"
    case .unknownItem: "unknownItem"
    case .serverRecordChanged: "serverRecordChanged"
    case .quotaExceeded: "quotaExceeded"
    case .permissionFailure: "permissionFailure"
    case .badContainer: "badContainer"
    case .missingEntitlement: "missingEntitlement"
    case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
    case .partialFailure: "partialFailure"
    case .invalidArguments: "invalidArguments"
    case .serverRejectedRequest: "serverRejectedRequest"
    case .operationCancelled: "operationCancelled"
    case .internalError: "internalError"
    default: "CKError \(code.rawValue)"
    }
  }
}
