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
  /// What the agent is waiting on, oldest first (#40). The CLIs draw one dialog at a time, in the
  /// order they asked: the first is the one on screen.
  public var requests: [AgentRequest] = []
  /// A tool settled that may, or may not, have been the first request's: which dialog is on
  /// screen is no longer known, and none is answered from outside until the queue drains.
  public var isFirstRequestUncertain = false
  /// A request was taken away on a guess: the dialog on screen may be one the queue no longer
  /// holds, however few are left in it. The doubt then lasts until the queue drains.
  var isTrackLost = false

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
  /// Vibe Manager typed the answer to this request into the terminal (#40).
  case answerSent(AgentRequestID)
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
  /// What a request the input brings is known by: its session and the line that carried it.
  public let requestID: AgentRequestID?

  public init(
    now: Date,
    isVisible: Bool,
    approvalAnswerKeys: Set<[UInt8]> = [],
    requestID: AgentRequestID? = nil
  ) {
    self.now = now
    self.isVisible = isVisible
    self.approvalAnswerKeys = approvalAnswerKeys
    self.requestID = requestID
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
      next.clearRequests()

    case .processEnded:
      next.activity = .idle
      next.lastOutputAt = nil
      next.clearRequests()

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
        // Provisional: the next thing the agent says confirms it or puts the question back. The
        // key answered the dialog on screen — the first of the queue, when its order is known.
        if next.requests.isEmpty {
          next.activity = .working
        } else {
          next.settleFirstRequest(isKnownAnswered: !next.isFirstRequestUncertain)
        }
      case .working where interruptKeys.contains(bytes):
        next.activity = .idle
      case .idle, .working, .awaitingUser:
        break
      }

    case .answerSent(let id):
      guard next.requests.first?.id == id else { break }
      next.settleFirstRequest(isKnownAnswered: true)

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
      // A background task finishing starts a turn of the main agent while a sub-agent's dialog
      // is still up (seen in the spike of #40): what waits keeps waiting.
      next.activity = next.requests.first.map { .awaitingUser($0.kind) } ?? .working
      // Writing to the agent is reading what it said last.
      if byUser { next.unreadSince = nil }
    case .questionAsked(let kind, let tool, let notice):
      next.pendingTool = tool
      next.enqueue(notice, kind: kind, tool: tool, context: context)
      next.activity = .awaitingUser(next.requests.first?.kind ?? kind)
    case .questionResolved:
      // Nothing says which request was answered. Alone, it was; behind others, the first is taken
      // as the one, and the dialog on screen is no longer known for sure.
      if next.requests.count > 1 {
        next.settleFirstRequest(isKnownAnswered: false)
      } else {
        next.clearRequests()
        next.activity = .working
      }
    case .toolFinished(let tool, let agentID, let subject):
      guard !next.requests.isEmpty else {
        // Sub-agents run tools side by side: one finishing answers nothing another is waiting on.
        if case .awaitingUser = next.activity, let pending = next.pendingTool, pending != tool {
          break
        }
        next.activity = .working
        break
      }
      next.settle(AgentToolReference(tool: tool, agentID: agentID, subject: subject))
    case .turnEnded:
      // A sub-agent in the background can still be waiting on the user once the main turn ends —
      // on a dialog it drew. One announced by its tool and never drawn may never be: a hook of
      // the user's own can stop the tool before either. Should it be drawn after all, its
      // `PermissionRequest` queues it again.
      next.requests.removeAll { !$0.isShown }
      if next.requests.isEmpty { next.clearRequests() }
      next.activity = next.requests.first.map { .awaitingUser($0.kind) } ?? .idle
      if !context.isVisible { next.unreadSince = next.unreadSince ?? context.now }
    case .interrupted, .agentEnded:
      next.activity = .idle
      next.clearRequests()
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
  /// from are nobody's to see. The requests are shown by the palette of #40.
  public func showsTheSame(as other: AgentActivityState) -> Bool {
    activity == other.activity && unreadSince == other.unreadSince && source == other.source
      && requests == other.requests && isFirstRequestUncertain == other.isFirstRequestUncertain
  }

  // MARK: - Requests (#40)

  mutating func clearRequests() {
    requests = []
    isFirstRequestUncertain = false
    isTrackLost = false
  }

  /// Queues what an agent asked. Its dialog drawn, a request already announced by its tool is
  /// the same one, now shown.
  mutating func enqueue(
    _ notice: AgentRequestNotice?,
    kind: AgentQuestionKind,
    tool: String?,
    context: AgentActivityContext
  ) {
    let notice =
      notice
      ?? AgentRequestNotice(
        content: kind == .approval ? .unreadable(tool: tool) : .elicitation,
        reference: AgentToolReference(tool: tool), isShown: false)
    if let index = requests.firstIndex(where: {
      !$0.isShown && $0.reference.match(notice.reference) == .same
    }) {
      // Drawn behind a dialog that was drawn before it: the queue's order is not the screen's.
      if notice.isShown, requests[(index + 1)...].contains(where: \.isShown) {
        isFirstRequestUncertain = true
      }
      requests[index].isShown = requests[index].isShown || notice.isShown
      // The dialog's report may be cut short where the tool's was not.
      if !notice.content.isUnreadable { requests[index].content = notice.content }
      return
    }
    guard let base = context.requestID else { return }
    let id = notice.key.map { AgentRequestID(sessionID: base.sessionID, key: $0) } ?? base
    // The same report read twice — a log replayed after an adoption — is one request.
    guard !requests.contains(where: { $0.id == id }) else { return }
    // Two hooks run side by side append their lines in no guaranteed order: two requests in the
    // same second may be on screen in the other order, and neither is answered from outside
    // until one is settled. The lines are stamped to the whole second, so two stamps one apart
    // may be a moment apart.
    if let last = requests.last, abs(context.now.timeIntervalSince(last.receivedAt)) <= 1 {
      isFirstRequestUncertain = true
    }
    requests.append(
      AgentRequest(
        id: id, receivedAt: context.now, kind: kind, content: notice.content,
        reference: notice.reference, isShown: notice.isShown))
  }

  /// The first request was taken as answered: the next one's dialog takes its place.
  /// `isKnownAnswered` says it was the one answered; otherwise it was a guess.
  mutating func settleFirstRequest(isKnownAnswered: Bool) {
    guard !requests.isEmpty else { return }
    requests.removeFirst()
    if requests.isEmpty {
      clearRequests()
    } else if !isKnownAnswered {
      isFirstRequestUncertain = true
      isTrackLost = true
    } else if requests.count == 1, !isTrackLost {
      // Alone, the one left is the dialog on screen.
      isFirstRequestUncertain = false
    }
    if requests.isEmpty {
      activity = .working
    } else {
      activity = .awaitingUser(requests[0].kind)
    }
  }

  /// A tool ran or was refused. It settles the request it matches; one that might be the first
  /// without it being sure takes the first away and leaves the next in doubt.
  mutating func settle(_ reference: AgentToolReference) {
    if let first = requests.first, first.reference.match(reference) == .same {
      settleFirstRequest(isKnownAnswered: true)
    } else if let index = requests.firstIndex(where: { $0.reference.match(reference) == .same }) {
      // Settled out of turn: the dialogs are not drawn in the order they were asked after all.
      requests.remove(at: index)
      if requests.isEmpty {
        clearRequests()
      } else {
        // Alone, the one left is the dialog on screen — unless a guess already lost track.
        isFirstRequestUncertain = requests.count > 1 || isTrackLost
      }
    } else if let first = requests.first, first.reference.match(reference) == .likely {
      settleFirstRequest(isKnownAnswered: false)
    }
  }
}
