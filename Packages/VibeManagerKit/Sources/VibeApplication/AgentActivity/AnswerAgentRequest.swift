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
  public struct Failure: Sendable {
    public let requestID: String
    public let outcome: Outcome
    public let request: String
    public let answer: String
    public let before: String
    public let after: String
    public let keys: [[UInt8]]
    public let writtenKeys: [[UInt8]]

    public init(
      requestID: String, outcome: Outcome, request: String, answer: String,
      before: String, after: String, keys: [[UInt8]], writtenKeys: [[UInt8]]
    ) {
      self.requestID = requestID
      self.outcome = outcome
      self.request = request
      self.answer = answer
      self.before = before
      self.after = after
      self.keys = keys
      self.writtenKeys = writtenKeys
    }
  }
  public enum Outcome: String, Hashable, Sendable, DiagnosticTokenConvertible {
    case sent
    /// The request is no longer the one on screen: answered, refused or gone meanwhile.
    case requestGone
    /// The request is there, but this answer cannot be given to it from outside.
    case notAnswerable
    /// The session has no running terminal to type into.
    case terminalUnavailable
    /// The request went away between two keystrokes of a longer answer, or its dialog did not move
    /// on to what the next one answers: the rest was not typed.
    case interrupted
    /// The dialog drawn in the terminal does not offer this answer, or could not be read: nothing
    /// was typed (#273).
    case notOnScreen
    /// The dialog drawn in the terminal is not known to be the request's: it shows another's, or
    /// one more request's, or cannot be read whole. Nothing was typed (#283).
    case otherDialog
  }

  /// How long a terminal must stay silent before the next keystroke, and how long it is waited for
  /// at most: an interface redraws after each key, and the next one must reach the redrawn dialog.
  public static let quietPeriod: Duration = .milliseconds(80)
  public static let settleLimit: Duration = .seconds(1)

  private let tracker: TrackAgentActivity
  private let write: @Sendable (SessionID, [UInt8]) async -> Bool
  private let lastOutput: @Sendable (SessionID) async -> ContinuousClock.Instant?
  private let screen: @Sendable (SessionID) async -> String?
  private let sleep: @Sendable (Duration) async throws -> Void
  private let diagnostics: Diagnostics
  private let confirmsDelivery: Bool
  private let failed: @Sendable (Failure) async -> Void

  /// - Parameters:
  ///   - write: types bytes into the session's running terminal; `false` when none runs.
  ///   - lastOutput: when the session's terminal last wrote something.
  ///   - screen: what the session's terminal shows now, as text; `nil` when it cannot be told.
  public init(
    tracker: TrackAgentActivity,
    write: @escaping @Sendable (SessionID, [UInt8]) async -> Bool,
    lastOutput: @escaping @Sendable (SessionID) async -> ContinuousClock.Instant? = { _ in nil },
    screen: @escaping @Sendable (SessionID) async -> String? = { _ in nil },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    diagnostics: Diagnostics = .disabled,
    confirmsDelivery: Bool = false,
    failed: @escaping @Sendable (Failure) async -> Void = { _ in }
  ) {
    self.tracker = tracker
    self.write = write
    self.lastOutput = lastOutput
    self.screen = screen
    self.sleep = sleep
    self.diagnostics = diagnostics
    self.confirmsDelivery = confirmsDelivery
    self.failed = failed
  }

  @discardableResult
  public func callAsFunction(_ answer: AgentAnswer, to id: AgentRequestID) async -> Outcome {
    let request = await tracker.state(for: id.sessionID)?.requests.first { $0.id == id }
    let before = await screen(id.sessionID)
    let keys =
      await tracker.keystrokes(
        for: answer, to: id, screen: before.flatMap(AgentDialogScreen.init(screen:))) ?? []
    var written: [[UInt8]] = []
    let outcome = await give(answer, to: id, written: &written)
    if [.notOnScreen, .otherDialog, .interrupted].contains(outcome), let request {
      await failed(
        Failure(
          requestID: String(describing: id), outcome: outcome,
          request: String(reflecting: request.content), answer: answer.reported,
          before: answer.withoutTypedText(before ?? "<unavailable>"),
          after: answer.withoutTypedText(await screen(id.sessionID) ?? "<unavailable>"),
          keys: keys, writtenKeys: written))
    }
    diagnostics.record(
      .session, outcome == .sent ? .info : .notice, "request.answered",
      [
        "session": diagnostics.pseudonym(id.sessionID), "outcome": .token(DiagnosticToken(outcome)),
        "answer": .token(answer.diagnosticToken),
      ])
    return outcome
  }

  private func give(_ answer: AgentAnswer, to id: AgentRequestID, written: inout [[UInt8]]) async
    -> Outcome
  {
    guard await tracker.offers(answer, to: id) else {
      return await tracker.isFirstRequest(id) ? .notAnswerable : .requestGone
    }
    var text = await screen(id.sessionID)
    // Whose dialog is drawn is read off the screen, against every request the agent reported
    // before drawing it (#283). The screen is read first: every dialog on it was reported by then,
    // and once the log is read up to its end, every report is known. Read again after, it must
    // show the same dialog — the keys are taken from that last reading.
    if await tracker.readsRequestsOnScreen(id.sessionID) {
      let before = text
      guard await tracker.catchUp(id.sessionID), let before else {
        return await tracker.isFirstRequest(id) ? .otherDialog : .requestGone
      }
      text = await screen(id.sessionID)
      guard let text, await tracker.dialogOnScreen(text, readBefore: before, isFor: id) else {
        return await tracker.isFirstRequest(id) ? .otherDialog : .requestGone
      }
    }
    // Which key takes the answer is read off the dialog as drawn now (#273).
    let drawn = text.flatMap(AgentDialogScreen.init(screen:))
    guard let steps = await tracker.keystrokes(for: answer, to: id, screen: drawn),
      !steps.isEmpty
    else {
      return await tracker.isFirstRequest(id) ? .notOnScreen : .requestGone
    }
    var finalScreen = text
    for (index, step) in steps.enumerated() {
      if index > 0 {
        await settle(id.sessionID)
        // Whatever the agent said meanwhile may have taken the dialog away: the next key would
        // then land in its prompt.
        guard await tracker.isFirstRequest(id) else { return .interrupted }
        // A key the dialog has not taken yet, or has taken otherwise: the rest is not typed, and
        // the request still waits — never shown answered while the terminal asks on.
        if await tracker.rereadsScreen(beforeStep: index, of: answer, for: id),
          await !screenAsks(Array(steps[index...]), of: answer, to: id)
        {
          return .interrupted
        }
      }
      // Earlier answers may already have advanced to a review. Only leaving the
      // dialog that awaits the final key proves the whole interaction completed.
      if confirmsDelivery, index == steps.count - 1 {
        finalScreen = await screen(id.sessionID)
      }
      guard await write(id.sessionID, step) else { return .terminalUnavailable }
      written.append(step)
    }
    if confirmsDelivery {
      let original = finalScreen.flatMap(AgentDialogScreen.init(screen:))
      let start = ContinuousClock.now
      var changedReadings = 0
      while await tracker.isFirstRequest(id) {
        await settle(id.sessionID)
        if let current = await screen(id.sessionID) {
          let dialog = AgentDialogScreen(screen: current)
          let changed =
            original == nil
            ? finalScreen.map { current != $0 } ?? false
            : (dialog?.options != original?.options
              || dialog?.confirmation?.server != original?.confirmation?.server
              || dialog?.confirmation?.message != original?.confirmation?.message
              || dialog?.folderTrust?.folder != original?.folderTrust?.folder)
          changedReadings =
            changed && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? changedReadings + 1 : 0
          if changedReadings >= 2 { break }
        }
        guard ContinuousClock.now - start < .seconds(3), !Task.isCancelled else {
          return .interrupted
        }
      }
    }
    await tracker.answerSent(id)
    return .sent
  }

  /// Observe the real dialog after a permission hook, without typing any answer. Automatic
  /// review can finish without one; terminal input approvals may draw without an OSC notice.
  public func followPermissionDialog(_ id: AgentRequestID) async {
    while !Task.isCancelled, await tracker.awaitsPermissionDialog(id) {
      if let before = await screen(id.sessionID), await tracker.catchUp(id.sessionID),
        !Task.isCancelled, let after = await screen(id.sessionID)
      {
        if await tracker.dialogOnScreen(after, readBefore: before, isFor: id) { return }
        // Drawn, but not to be told apart: shown to be answered in the terminal, and still read
        // until it is told apart, or settled.
        await tracker.dialogUnnamedOnScreen(after, readBefore: before, isFor: id)
      }
      do { try await sleep(Self.startupDialogPollInterval) } catch { return }
    }
  }

  /// Reads which dialog of its start a session waits on, off its screen: one its keymap answers
  /// — an update offered — takes the place of the request that only guessed one is there.
  ///
  /// Whether the screen shows a dialog: options numbered, one pointed at, near the bottom — or an
  /// MCP server's confirmation, or a folder to trust. Anything else is an agent still starting:
  /// Claude Code draws its banner before its hooks run, and on a busy Mac, dozens of sessions
  /// resumed together take far longer than the guess waits to draw their prompt (#474).
  @discardableResult
  public func readStartupDialog(_ id: AgentRequestID) async -> Bool {
    guard let text = await screen(id.sessionID) else { return false }
    await tracker.startupDialogOnScreen(text, isFor: id)
    return AgentDialogScreen(screen: text) != nil
  }

  /// Reads the dialog of a session's start again and again, as long as it waits: it may be drawn
  /// after the guess, and it goes when answered in the terminal — the card with it.
  /// `dialogDrawn` is called once, when the screen first shows a dialog: only then is one known
  /// to wait there.
  public func followStartupDialog(
    _ id: AgentRequestID, dialogDrawn: @escaping @Sendable () async -> Void = {}
  ) async {
    var isDrawn = false
    while await tracker.waitsOnStartupDialog(id), !Task.isCancelled {
      if await readStartupDialog(id), !isDrawn {
        isDrawn = true
        await dialogDrawn()
      }
      do {
        try await sleep(Self.startupDialogPollInterval)
      } catch {
        return
      }
    }
  }

  /// How often the screen of a start that waits is read again.
  public static let startupDialogPollInterval: Duration = .seconds(1)

  /// Whether the dialog, read again, asks for `keys` and nothing else — waited for up to
  /// `settleLimit`, the key before having to be read and drawn first.
  private func screenAsks(_ keys: [[UInt8]], of answer: AgentAnswer, to id: AgentRequestID) async
    -> Bool
  {
    let start = ContinuousClock.now
    while true {
      let drawn = await screen(id.sessionID).flatMap(AgentDialogScreen.init(screen:))
      let left = await tracker.keystrokesLeft(for: answer, to: id, screen: drawn)
      if left == keys { return true }
      // A preview already pointing at the requested choice still accepts its digit again.
      if keys.count >= 2, keys[1] == TerminalKeys.enter,
        keys[0].count == 1, (49...57).contains(keys[0][0]), left == Array(keys.dropFirst())
      {
        return true
      }
      guard ContinuousClock.now - start < Self.settleLimit else { return false }
      do {
        try await sleep(Self.quietPeriod)
      } catch {
        return false
      }
    }
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
    case .skipUpdate: return "skipUpdate"
    case .chatAboutThis: return "chatAboutThis"
    case .trustFolder: return "trustFolder"
    }
  }
}

extension AgentAnswer {
  /// What a failure report says of this answer: a text the user typed by its length only, as
  /// the key traces already do. Options, choices and refusals are kept, to reproduce the case.
  public var reported: String {
    guard case .answers(let answers) = self else { return String(reflecting: self) }
    let each = answers.map { answer -> String in
      guard case .text(let text) = answer else { return String(reflecting: answer) }
      return ".text(<\(text.count) characters omitted>)"
    }
    return ".answers([\(each.joined(separator: ", "))])"
  }

  /// A screen with the text the user typed taken out where it shows whole: what the field of
  /// the dialog echoes. A text wrapped over several lines may still show in part.
  public func withoutTypedText(_ screen: String) -> String {
    guard case .answers(let answers) = self else { return screen }
    return answers.reduce(screen) { screen, answer in
      guard case .text(let text) = answer, !text.isEmpty else { return screen }
      return screen.replacingOccurrences(of: text, with: "<typed text omitted>")
    }
  }
}
