import Foundation

/// A creation that did not happen: all that was asked, and why.
public struct ReturnedCreation: Equatable, Sendable {
  public let request: RemoteNewSession
  public let error: String

  public init(request: RemoteNewSession, error: String) {
    self.request = request
    self.error = error
  }
}

/// A session asked of the Mac from the phone (#470), from the moment the form closes to the Mac's
/// answer. The protocol does not say which request an answer is for, so one is in flight at a time:
/// a request given up on still counts until the Mac answers it, the connection goes, or a request
/// held behind it expires too.
///
/// The Mac answers on the connection that asked. A request whose connection closed before the
/// answer — the phone locked a second after Create — may still have been made: the Mac's first
/// list of sessions, on the next connection, is then the only answer left.
public struct RemoteCreation: Sendable {
  public enum Answer: Equatable, Sendable {
    /// What is being created now exists, or one given up on does after all.
    case created(String)
    case failed(RemoteNewSession, RemoteFailure)
    /// The request given up on is settled and did not make this one: it can go.
    case send(RemoteNewSession)
    /// Nothing the phone waits for: the answer to a request already told as failed.
    case ignored
  }

  /// What is shown as being created.
  public private(set) var pending: RemoteNewSession?
  /// Whether `pending` went out on the current connection, which alone can answer it.
  private var isWritten = false
  private var givenUp: RemoteNewSession?
  /// The request written on a connection that closed before the Mac answered it: perhaps made, which
  /// only the Mac's first list on the next connection can still tell.
  private var unanswered: RemoteNewSession?
  /// The sessions the Mac listed when the request in flight was written: the one it makes is none
  /// of them.
  private var known: Set<String> = []
  /// A creation that came back once the user had left the waiting screen: never shown over
  /// another screen, it waits for the next New Session.
  private var kept: ReturnedCreation?

  public init() {}

  /// A creation that came back (#470): what to show now, on the waiting screen; elsewhere `nil`,
  /// and it is kept for the next New Session.
  public mutating func returned(_ creation: ReturnedCreation, isWaiting: Bool)
    -> ReturnedCreation?
  {
    kept = isWaiting ? nil : creation
    return isWaiting ? creation : nil
  }

  /// What New Session opens with: the creation kept, once. Another asked meanwhile, or the session
  /// found after all, and nothing is.
  public mutating func takeKept() -> ReturnedCreation? {
    defer { kept = nil }
    return kept
  }

  /// Whether what is shown as being created went out on a connection lost before the Mac answered:
  /// the session may exist, and asking again could make a second one.
  public var isUnanswered: Bool {
    pending != nil && pending == unanswered
  }

  /// Asks for a session; `false` when nothing is to be written: one is already being created, or
  /// this one is held behind the request given up on, so that one late answer cannot make two.
  /// `listed` is what the Mac listed until now, none of which this request can make.
  public mutating func submit(_ request: RemoteNewSession, listed: [RemoteSession] = []) -> Bool {
    guard pending == nil else { return false }
    pending = request
    kept = nil
    isWritten = givenUp == nil
    if isWritten {
      known = Set(listed.map(\.id))
      unanswered = nil
    }
    return isWritten
  }

  /// No answer in time: what was asked, for the form. Only a request written can still be answered.
  public mutating func expire() -> RemoteNewSession? {
    guard let request = pending else { return nil }
    givenUp = isWritten ? request : nil
    pending = nil
    isWritten = false
    return request
  }

  /// An answer of the old connection can no longer come; the request it took may still be found
  /// in the Mac's list.
  public mutating func connectionLost() {
    if let request = isWritten ? pending : givenUp { unanswered = request }
    isWritten = false
    givenUp = nil
  }

  /// `nil` when nothing waits for it.
  public mutating func created(_ id: String) -> Answer? {
    let wasGivenUp = givenUp
    givenUp = nil
    // Held and different: the session that exists is not the one asked for now.
    if let request = pending, !isWritten, let wasGivenUp, request != wasGivenUp {
      isWritten = true
      known.insert(id)
      return .send(request)
    }
    guard pending != nil || wasGivenUp != nil else { return nil }
    pending = nil
    isWritten = false
    // Made after all: a form kept for it would make a second.
    kept = nil
    return .created(id)
  }

  /// `nil` when the failure is not about a creation, for the alert any failure gets.
  public mutating func failed(_ failure: RemoteFailure) -> Answer? {
    switch failure {
    case .folderMissing, .noAgent, .other: break
    default: return nil
    }
    if givenUp != nil {
      givenUp = nil
      guard let request = pending else { return .ignored }
      isWritten = true
      return .send(request)
    }
    guard isWritten, let request = pending else { return nil }
    pending = nil
    isWritten = false
    return .failed(request, failure)
  }

  /// The Mac's sessions, as each connection lists them. The first list after a connection lost
  /// settles its unanswered request: the session it made, if there, is taken as the Mac's answer;
  /// otherwise it was never made, and a form kept for it says so with `noAnswer`. No later list
  /// does: a session of that name made long after is not that one.
  public mutating func listed(_ sessions: [RemoteSession], noAnswer: String) -> Answer? {
    guard let request = unanswered else { return nil }
    unanswered = nil
    let ids = Set(sessions.map(\.id))
    // A list that shares none of the sessions known then is another Mac's.
    guard known.isEmpty || !known.isDisjoint(with: ids),
      let made = sessions.last(where: { !known.contains($0.id) && Self.isMade(request, as: $0) })
    else {
      if kept?.request == request { kept = ReturnedCreation(request: request, error: noAnswer) }
      return nil
    }
    givenUp = request
    return created(made.id)
  }

  /// Whether `session` is what the Mac makes of `request`: no coordinator's child, a coordinator
  /// when asked to be, and named as the Mac names it — the name typed, else the first line of the
  /// message, else the folder's name, on one line.
  static func isMade(_ request: RemoteNewSession, as session: RemoteSession) -> Bool {
    guard session.coordinatorID == nil, session.isCoordinator == request.coordinates else {
      return false
    }
    let typed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine =
      request.prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    let taken = firstLine.isEmpty ? (request.folder as NSString).lastPathComponent : firstLine
    let name = typed.isEmpty ? String(taken.prefix(60)) : typed
    return session.name == oneLine(name)
  }

  /// A name as the Mac stores it: its line breaks and tabs turned into spaces, trimmed.
  private static func oneLine(_ name: String) -> String {
    String(
      String.UnicodeScalarView(
        name.unicodeScalars.map {
          CharacterSet.newlines.contains($0) || $0 == "\t" ? " " : $0
        })
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
