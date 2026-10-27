import Foundation

/// Return written into an agent whose prompt the screen shows (#370): it waits for the prompt to
/// show the text typed, and a prompt that still shows it once Return is written is sent again,
/// once. Return written before the agent took the text was seen to break the line, or to be lost.
/// The composer's messages go this way, and the application's (#435).
public struct PromptReturn: Sendable {
  /// How long Return waits for the agent's prompt to show the text typed.
  public var inputWaitLimit = Duration.seconds(3)
  /// How long a prompt still showing the text once Return is written is given to be sent.
  public var sendWaitLimit = Duration.milliseconds(1500)
  /// How long after Return a reading of the screen starts for it to tell whether Return was taken:
  /// one started sooner may show the prompt as it was before the agent read the key.
  public var sendSettleDelay = Duration.milliseconds(300)
  /// Between two readings of the screen: each replays the terminal's history.
  public static let screenReadInterval = Duration.milliseconds(100)
  public static let backspace: [UInt8] = [0x7F]

  public init() {}

  /// Reads the agent's prompt on its screen until `done` says so, or `limit` has passed and a
  /// reading started at `earliest` at least, and returns the last one read: nil when the screen
  /// shows none, which tells nothing.
  @MainActor public static func readInput(
    _ readScreen: () async -> String?, for limit: Duration,
    notBefore earliest: ContinuousClock.Instant = .now, until done: ([String]) -> Bool
  ) async -> [String]? {
    let deadline = ContinuousClock.now + limit
    while true {
      let started = ContinuousClock.now
      guard let screen = await readScreen(),
        let input = PromptInputRecognition.input(screen: screen)
      else { return nil }
      if done(input) || Task.isCancelled { return input }
      if ContinuousClock.now >= deadline && started >= earliest { return input }
      try? await Task.sleep(for: screenReadInterval)
    }
  }

  @MainActor public func waitForInput(holding text: String, _ readScreen: () async -> String?) async
  {
    _ = await Self.readInput(readScreen, for: inputWaitLimit) { Self.held(text, $0) }
  }

  /// Return written, reads whether the prompt still shows the text: the input then, once a line
  /// break seen twice running or `sendWaitLimit` passed; nil once sent, or when the screen tells
  /// nothing.
  @MainActor public func inputStillHolding(_ text: String, _ readScreen: () async -> String?) async
    -> [String]?
  {
    let earliest = ContinuousClock.now + sendSettleDelay
    var lineBreakSeen = false
    guard
      let input = await Self.readInput(
        readScreen, for: sendWaitLimit, notBefore: earliest,
        until: { input in
          guard Self.held(text, input) else { return true }
          // Seen twice running, a line break is no prompt being redrawn: it is not waited out.
          let lineBreak = PromptInputRecognition.endsOnLineBreak(input)
          defer { lineBreakSeen = lineBreak }
          return lineBreak && lineBreakSeen
        }),
      Self.held(text, input)
    else { return nil }
    return input
  }

  /// Writes Return again into a prompt that still holds the text: its line break erased first
  /// when Return was taken for one, as it is when Return was lost.
  @MainActor public static func submitAgain(
    _ input: [String], submit: [UInt8], write: ([UInt8]) async -> Void
  ) async {
    if PromptInputRecognition.endsOnLineBreak(input) { await write(backspace) }
    await write(submit)
  }

  public static func held(_ text: String, _ input: [String]) -> Bool {
    PromptInputRecognition.holds(text, in: input) || PromptInputRecognition.showsPastedText(input)
  }
}
