import Foundation

/// What is known about one session's agent, and how far it can be trusted.
public struct AgentActivityState: Hashable, Sendable {
  /// Where the activity comes from.
  public enum Source: Hashable, Sendable {
    /// Launched with hooks that have not spoken yet. Treated as `inferred` until they do.
    case unconfirmed(since: Date)
    /// The agent's hooks report what it does.
    case structured
    /// Nothing structured: read from the terminal's output alone, which can tell working from
    /// waiting and nothing more.
    case inferred
  }

  public var activity: AgentActivity
  /// When an answer finished that the user has not seen yet.
  public var unreadSince: Date?
  public var source: Source
  /// Inferred sources only: when the terminal last wrote something the user did not cause.
  var lastOutputAt: Date?
  /// When the user last typed into this session's terminal.
  var lastUserInputAt: Date?
  /// The tool the pending question holds up, when the hooks named it.
  var pendingTool: String?

  public init(
    activity: AgentActivity = .idle,
    unreadSince: Date? = nil,
    source: Source = .inferred
  ) {
    self.activity = activity
    self.unreadSince = unreadSince
    self.source = source
  }

  /// Whether this state holds anything worth writing down for the next launch.
  public var isWorthKeeping: Bool {
    activity != .idle || unreadSince != nil
  }
}

/// Everything that can move an agent's state.
public enum AgentActivityInput: Hashable, Sendable {
  /// A process started for the session. `structured` says whether it was launched with hooks.
  case processStarted(structured: Bool)
  case processEnded
  case signal(AgentSignal)
  /// The terminal wrote something.
  case output
  /// The user typed this into the session's terminal, in one write.
  case userInput([UInt8])
  /// Time passed: the deadlines the state is waiting on are checked.
  case tick
}

/// What the machine needs to know about the world beyond the state itself.
public struct AgentActivityContext: Sendable {
  public let now: Date
  /// Whether the session is in front of the user right now: an answer finished while it is shown
  /// has been read as it arrived.
  public let isVisible: Bool
  /// The single keystrokes that answer a permission in this agent's terminal interface.
  public let approvalAnswerKeys: Set<[UInt8]>

  public init(now: Date, isVisible: Bool, approvalAnswerKeys: Set<[UInt8]> = []) {
    self.now = now
    self.isVisible = isVisible
    self.approvalAnswerKeys = approvalAnswerKeys
  }
}

/// The rules of #45, with nothing around them: no disk, no process, no clock of its own.
public enum AgentActivityMachine {
  /// How long hooks get to say they are there before the session falls back on its output.
  public static let confirmationTimeout: Duration = .seconds(10)
  /// Without hooks, how long a silent terminal still counts as a working agent.
  public static let inferredSilence: Duration = .seconds(3)
  /// Output this close behind a keystroke is its echo, not the agent working.
  public static let echoWindow: Duration = .milliseconds(300)

  /// The keystrokes that stop a turn in both terminal interfaces, on their own in one write. An
  /// arrow key also starts with Escape, but arrives as a whole sequence.
  public static let interruptKeys: Set<[UInt8]> = [[0x1B], [0x03]]

  public static func reduce(
    _ state: AgentActivityState,
    _ input: AgentActivityInput,
    context: AgentActivityContext
  ) -> AgentActivityState {
    var next = state
    switch input {
    case .processStarted(let structured):
      // A new process has no question pending and has said nothing yet. What was left unread
      // by the previous one still is: the user never saw it.
      next.activity = .idle
      next.source = structured ? .unconfirmed(since: context.now) : .inferred
      next.lastOutputAt = nil
      next.lastUserInputAt = nil

    case .processEnded:
      next.activity = .idle
      next.lastOutputAt = nil

    case .signal(let signal):
      next = apply(signal, to: next, context: context)

    case .output:
      guard !next.isStructured else { break }
      if let typed = next.lastUserInputAt, context.now.timeIntervalSince(typed) < echoWindow.seconds
      {
        break
      }
      next.lastOutputAt = context.now
      next.activity = .working

    case .userInput(let bytes):
      next.lastUserInputAt = context.now
      guard next.isStructured else { break }
      switch next.activity {
      case .awaitingUser(.approval) where context.approvalAnswerKeys.contains(bytes):
        // Provisional: the next thing the agent says confirms it or puts the question back.
        next.activity = .working
      case .working where interruptKeys.contains(bytes):
        next.activity = .idle
      case .idle, .working, .awaitingUser:
        break
      }

    case .tick:
      if case .unconfirmed(let since) = next.source,
        context.now.timeIntervalSince(since) >= confirmationTimeout.seconds
      {
        next.source = .inferred
      }
      if !next.isStructured, next.activity == .working,
        let last = next.lastOutputAt ?? next.lastUserInputAt,
        context.now.timeIntervalSince(last) >= inferredSilence.seconds
      {
        next.activity = .idle
      }
    }
    return next
  }

  private static func apply(
    _ signal: AgentSignal,
    to state: AgentActivityState,
    context: AgentActivityContext
  ) -> AgentActivityState {
    var next = state
    // Anything the hooks say proves they are wired, even when their `SessionStart` came late —
    // after the fallback already took over.
    next.source = .structured
    next.lastOutputAt = nil
    switch signal {
    case .channelConfirmed:
      // What the output suggested before the hooks spoke — a startup screen drawn, a history
      // replayed — was a guess, and nothing structured would ever take it back: an agent that has
      // just started waits for its prompt.
      if !state.isStructured { next.activity = .idle }
    case .promptSubmitted(let byUser):
      next.activity = .working
      // Writing to the agent is reading what it said last.
      if byUser { next.unreadSince = nil }
    case .questionAsked(let kind, let tool):
      next.activity = .awaitingUser(kind)
      next.pendingTool = tool
    case .questionResolved:
      next.activity = .working
    case .toolFinished(let tool):
      // Sub-agents run tools side by side: one finishing answers nothing another is waiting on.
      if case .awaitingUser = next.activity, let pending = next.pendingTool, pending != tool {
        break
      }
      next.activity = .working
    case .turnEnded:
      next.activity = .idle
      if !context.isVisible { next.unreadSince = next.unreadSince ?? context.now }
    case .interrupted, .agentEnded:
      next.activity = .idle
    case .waitingForInput:
      if next.activity == .working { next.activity = .idle }
    }
    return next
  }

  /// When the state next needs a `tick`, or `nil` when it waits on nothing.
  public static func nextDeadline(of state: AgentActivityState) -> Date? {
    var deadlines: [Date] = []
    if case .unconfirmed(let since) = state.source {
      deadlines.append(since.addingTimeInterval(confirmationTimeout.seconds))
    }
    if !state.isStructured, state.activity == .working,
      let last = state.lastOutputAt ?? state.lastUserInputAt
    {
      deadlines.append(last.addingTimeInterval(inferredSilence.seconds))
    }
    return deadlines.min()
  }
}

extension AgentActivityState {
  var isStructured: Bool {
    source == .structured
  }

  /// Whether a row showing either state would look the same: the instants the fallback counts
  /// from are nobody's to see.
  public func showsTheSame(as other: AgentActivityState) -> Bool {
    activity == other.activity && unreadSince == other.unreadSince && source == other.source
  }
}
