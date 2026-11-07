/// A session asked of the Mac from the phone (#470), from the moment the form closes to the Mac's
/// answer. The protocol does not say which request an answer is for, so one is in flight at a time:
/// a request given up on still counts until the Mac answers it, the connection goes, or a request
/// held behind it expires too.
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

  public init() {}

  /// Asks for a session; `false` when nothing is to be written: one is already being created, or
  /// this one is held behind the request given up on, so that one late answer cannot make two.
  public mutating func submit(_ request: RemoteNewSession) -> Bool {
    guard pending == nil else { return false }
    pending = request
    isWritten = givenUp == nil
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

  /// An answer of the old connection can no longer come.
  public mutating func connectionLost() {
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
      return .send(request)
    }
    guard pending != nil || wasGivenUp != nil else { return nil }
    pending = nil
    isWritten = false
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
}
