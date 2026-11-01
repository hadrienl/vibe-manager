/// A session asked of the Mac from the phone (#470), from the moment the form closes to the Mac's
/// answer. The protocol does not say which request an answer is for, so one is in flight at a time:
/// a request given up on still counts until the Mac answers it or the connection goes.
public struct RemoteCreation: Sendable {
  public enum Answer: Equatable, Sendable {
    /// What is being created now exists.
    case created(String)
    /// A request given up on exists after all: its form must not make it a second time.
    case createdLate(String)
    case failed(RemoteNewSession, RemoteFailure)
    /// The request given up on failed: the one held behind it can go.
    case send(RemoteNewSession)
    /// Nothing the phone waits for: the answer to a request already told as failed.
    case ignored
  }

  /// What is shown as being created.
  public private(set) var pending: RemoteNewSession?
  private var isGivenUpRequestOpen = false

  public init() {}

  /// Asks for a session; `false` holds it back behind the request given up on, so that one late
  /// answer cannot make two sessions.
  public mutating func submit(_ request: RemoteNewSession) -> Bool {
    pending = request
    return !isGivenUpRequestOpen
  }

  /// No answer in time: what was asked, for the form.
  public mutating func expire() -> RemoteNewSession? {
    guard let request = pending else { return nil }
    pending = nil
    isGivenUpRequestOpen = true
    return request
  }

  /// An answer of the old connection can no longer come.
  public mutating func connectionLost() {
    isGivenUpRequestOpen = false
  }

  /// `nil` when nothing waits for it.
  public mutating func created(_ id: String) -> Answer? {
    defer {
      pending = nil
      isGivenUpRequestOpen = false
    }
    if pending != nil { return .created(id) }
    return isGivenUpRequestOpen ? .createdLate(id) : nil
  }

  /// `nil` when the failure is not about a creation, for the alert any failure gets.
  public mutating func failed(_ failure: RemoteFailure) -> Answer? {
    switch failure {
    case .folderMissing, .noAgent, .other: break
    default: return nil
    }
    if isGivenUpRequestOpen {
      isGivenUpRequestOpen = false
      return pending.map(Answer.send) ?? .ignored
    }
    guard let request = pending else { return nil }
    pending = nil
    return .failed(request, failure)
  }
}
