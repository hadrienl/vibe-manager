import Foundation
import VibeDomain

/// Answers a request of an agent from outside its terminal (#40), by typing into that terminal
/// exactly what the user would.
///
/// No other way to the agent exists: no hook that decides, no API. What the terminal shows stays
/// true, and the answer reads in it afterwards as if it had been typed. The keys go to the
/// terminal of the request's own session, looked up when they are written — the session in front
/// of the user is never touched.
public struct AnswerAgentRequest: Sendable {
  public enum Outcome: String, Hashable, Sendable, DiagnosticTokenConvertible {
    case sent
    /// The request is no longer the one on screen: answered, refused or gone meanwhile.
    case requestGone
    /// The request is there, but this answer cannot be given to it from outside.
    case notAnswerable
    /// The session has no running terminal to type into.
    case terminalUnavailable
    /// The request went away between two keystrokes of a longer answer: the rest was not typed.
    case interrupted
  }

  /// How long a terminal must stay silent before the next keystroke, and how long it is waited for
  /// at most: an interface redraws after each key, and the next one must reach the redrawn dialog.
  public static let quietPeriod: Duration = .milliseconds(80)
  public static let settleLimit: Duration = .seconds(1)

  private let tracker: TrackAgentActivity
  private let write: @Sendable (SessionID, [UInt8]) async -> Bool
  private let lastOutput: @Sendable (SessionID) async -> ContinuousClock.Instant?
  private let sleep: @Sendable (Duration) async throws -> Void
  private let diagnostics: Diagnostics

  /// - Parameters:
  ///   - write: types bytes into the session's running terminal; `false` when none runs.
  ///   - lastOutput: when the session's terminal last wrote something.
  public init(
    tracker: TrackAgentActivity,
    write: @escaping @Sendable (SessionID, [UInt8]) async -> Bool,
    lastOutput: @escaping @Sendable (SessionID) async -> ContinuousClock.Instant? = { _ in nil },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    diagnostics: Diagnostics = .disabled
  ) {
    self.tracker = tracker
    self.write = write
    self.lastOutput = lastOutput
    self.sleep = sleep
    self.diagnostics = diagnostics
  }

  @discardableResult
  public func callAsFunction(_ answer: AgentAnswer, to id: AgentRequestID) async -> Outcome {
    let outcome = await give(answer, to: id)
    diagnostics.record(
      .session, outcome == .sent ? .info : .notice, "request.answered",
      [
        "session": diagnostics.pseudonym(id.sessionID), "outcome": .token(DiagnosticToken(outcome)),
        "answer": .token(answer.diagnosticToken),
      ])
    return outcome
  }

  private func give(_ answer: AgentAnswer, to id: AgentRequestID) async -> Outcome {
    guard let steps = await tracker.keystrokes(for: answer, to: id), !steps.isEmpty else {
      return await tracker.isFirstRequest(id) ? .notAnswerable : .requestGone
    }
    for (index, step) in steps.enumerated() {
      if index > 0 {
        await settle(id.sessionID)
        // Whatever the agent said meanwhile may have taken the dialog away: the next key would
        // then land in its prompt.
        guard await tracker.isFirstRequest(id) else { return .interrupted }
      }
      guard await write(id.sessionID, step) else { return .terminalUnavailable }
    }
    await tracker.answerSent(id)
    return .sent
  }

  /// Returns once the terminal has been silent for `quietPeriod`, or after `settleLimit`.
  private func settle(_ id: SessionID) async {
    let start = ContinuousClock.now
    repeat {
      do {
        try await sleep(Self.quietPeriod)
      } catch {
        return
      }
      guard let last = await lastOutput(id), ContinuousClock.now - last < Self.quietPeriod else {
        return
      }
    } while ContinuousClock.now - start < Self.settleLimit
  }
}

extension AgentAnswer {
  /// The kind of answer, for a diagnostic that must not hold what was answered.
  var diagnosticToken: DiagnosticToken {
    switch self {
    case .allowOnce: return "allowOnce"
    case .allowAlways: return "allowAlways"
    case .deny: return "deny"
    case .answers: return "answers"
    case .approvePlan: return "approvePlan"
    case .rejectPlan: return "rejectPlan"
    }
  }
}
