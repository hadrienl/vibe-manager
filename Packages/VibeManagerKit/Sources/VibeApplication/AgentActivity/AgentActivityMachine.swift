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
  /// A dialog the CLI said was drawn that no request reported yet is known to be (#273): its
  /// report, read from another file, may come after what the terminal wrote. It stands until
  /// something says the dialog was answered — never for a length of time (#280).
  var drawnBeforeReport: AgentDrawnDialog?

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
      // A dialog of the start waits until it is answered, whatever the terminal draws.
      if next.requests.isEmpty { next.activity = .working }

    case .userInput(let bytes):
      next.lastUserInputAt = context.now
      // The dialog of a start the hooks never spoke after (#273): only Return or Escape leaves it,
      // and no hook will say so.
      if !next.isStructured {
        if case .inTerminal(let prompt) = next.requests.first?.content, prompt.kind == .startup,
          bytes == [0x0D] || interruptKeys.contains(bytes)
        {
          next.settleFirstRequest(isKnownAnswered: true)
        }
        break
      }
      // A key that answers or leaves a dialog: the one drawn is gone, its report or not.
      if context.approvalAnswerKeys.contains(bytes) || interruptKeys.contains(bytes)
        || bytes == [0x0D]
      {
        next.drawnBeforeReport = nil
      }
      // A dialog only announced is answered in the terminal: a key that answers dialogs there is
      // taken as its answer, as nothing else will say it was. A form or a question takes words,
      // whose letters answer nothing: only Return or Escape ends it.
      if case .inTerminal(let prompt) = next.requests.first?.content {
        let ends =
          [.form, .question, .plan, .account, .startup].contains(prompt.kind)
          ? bytes == [0x0D] : context.approvalAnswerKeys.contains(bytes)
        if ends || interruptKeys.contains(bytes) {
          next.settleFirstRequest(isKnownAnswered: true)
        }
        break
      }
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
      next.drawnBeforeReport = nil
      next.settleFirstRequest(isKnownAnswered: true)

    case .tick:
      if case .unconfirmed(let since) = next.source,
        context.now.timeIntervalSince(since) >= confirmationTimeout.seconds
      {
        next.source = .inferred
        // Hooks that stay silent are held back by a dialog of the CLI's start, most likely: the
        // user is told there is one to answer (#273). The first word of the hooks takes it away.
        if next.requests.isEmpty {
          next.enqueue(
            AgentRequestNotice(
              content: .inTerminal(AgentTerminalPrompt(kind: .startup, message: nil)),
              reference: AgentToolReference(tool: nil), isShown: true, key: "startup"),
            kind: .approval, tool: nil, context: context)
          if !next.requests.isEmpty { next.activity = .awaitingUser(.approval) }
        }
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
    // after the fallback already took over. Whatever start held them back is behind the agent.
    next.source = .structured
    next.dropAnnouncedRequests { $0.kind == .startup }
    next.lastOutputAt = nil
    // A tool that ran, a new turn, its end: the dialog drawn before its report, if any, is gone.
    switch signal {
    case .promptSubmitted, .questionResolved, .toolFinished, .batchResolved, .turnEnded,
      .turnFailed, .interrupted, .agentEnded:
      next.drawnBeforeReport = nil
    case .channelConfirmed, .questionAsked, .dialogAnnounced, .dialogDrawn, .waitingForInput:
      break
    }
    switch signal {
    case .channelConfirmed:
      // What the output suggested before the hooks spoke — a startup screen drawn, a history
      // replayed — was a guess, and nothing structured would ever take it back: an agent that has
      // just started waits for its prompt.
      if !state.isStructured { next.activity = .idle }
    case .promptSubmitted(let byUser):
      // A dialog only announced was the main agent's: a new turn means it is behind it.
      if byUser { next.dropAnnouncedRequests() }
      // A background task finishing starts a turn of the main agent while a sub-agent's dialog
      // is still up (seen in the spike of #40): what waits keeps waiting.
      next.activity = next.requests.first.map { .awaitingUser($0.kind) } ?? .working
      // Writing to the agent is reading what it said last.
      if byUser { next.unreadSince = nil }
    case .questionAsked(let kind, let tool, let notice):
      // A dialog the main agent announced before this report of its own came is not this one; it
      // was answered, or it would still hold the agent back from asking. A sub-agent's says
      // nothing of it.
      if notice?.reference.agentID == nil { next.dropAnnouncedRequests() }
      next.pendingTool = tool
      let known = Set(next.requests.map(\.id))
      next.enqueue(notice, kind: kind, tool: tool, context: context)
      // Not always the last: an asynchronous question waits behind it.
      if let added = next.requests.firstIndex(where: { !known.contains($0.id) }) {
        next.reportFollows(drawnDialogAt: added)
      }
      next.activity = .awaitingUser(next.requests.first?.kind ?? kind)
    case .questionResolved:
      // Nothing says which request was answered. Alone, it was; behind others, the first is taken
      // as the one, and the dialog on screen is no longer known for sure.
      if next.heldRequestCount > 1 {
        next.settleFirstRequest(isKnownAnswered: false)
      } else if next.requests.count > 1 {
        next.settleFirstRequest(isKnownAnswered: true)
      } else {
        next.clearRequests()
        next.activity = .working
      }
    case .toolFinished(let tool, let agentID, let subject):
      // A tool finishing says nothing of an announced dialog: tools run side by side, and another
      // may end while it is still up (#271, #273).
      guard !next.requests.isEmpty else {
        // Sub-agents run tools side by side: one finishing answers nothing another is waiting on.
        if case .awaitingUser = next.activity, let pending = next.pendingTool, pending != tool {
          break
        }
        next.activity = .working
        break
      }
      next.settle(AgentToolReference(tool: tool, agentID: agentID, subject: subject))
    case .dialogAnnounced(let prompt):
      // Claude Code's notification repeats a dialog its `PermissionRequest` already reported, and
      // may come once it is answered: it only stands for one when nothing drawn waits (#273). A
      // question read from Codex's rollout is never known drawn, and Codex announces it too; one
      // asked without stopping the agent says nothing of its other dialogs.
      guard
        !next.requests.contains(where: {
          $0.isShown || ($0.kind == .question && (!$0.isAsynchronous || prompt.kind == .question))
        })
      else { break }
      let kind: AgentQuestionKind = prompt.kind == .question ? .question : .approval
      next.enqueue(
        AgentRequestNotice(
          content: .inTerminal(prompt), reference: AgentToolReference(tool: nil), isShown: true),
        kind: kind, tool: nil, context: context)
      next.activity = .awaitingUser(next.requests.first?.kind ?? kind)
    case .dialogDrawn(let dialog, let otherwise):
      // Only a command quoted whole names a request for sure (#280): the start of one, a file's
      // name, a server's, may be another request's — one reported later included — and a key
      // typed for the wrong card would answer this dialog. Such a dialog arms nothing: the
      // requests it may be are answered in the session.
      let matching = next.undrawnRequests(matching: dialog)
      guard !matching.isEmpty else {
        next.drawnBeforeReport = dialog
        if let otherwise { next = apply(.dialogAnnounced(otherwise), to: next, context: context) }
        break
      }
      next.drawnBeforeReport = nil
      guard dialog.quotesWhole, matching.count == 1 else {
        next.isFirstRequestUncertain = true
        break
      }
      next.arm(at: matching[0])
    case .batchResolved(let agentID):
      // What this agent asked is answered, one way or another. Another agent's request waits on.
      let isOthers = { (request: AgentRequest) in
        request.content.isAnnouncedOnly ? agentID != nil : request.reference.agentID != agentID
      }
      guard next.requests.contains(where: { !isOthers($0) }) else { break }
      let wasFirst = next.requests.first.map { !isOthers($0) } == true
      next.requests.removeAll { !isOthers($0) }
      if next.requests.isEmpty {
        next.clearRequests()
        next.activity = .working
      } else if wasFirst {
        // Which of the others is on screen is not known from this.
        next.isFirstRequestUncertain = next.heldRequestCount > 1 || next.isTrackLost
        next.activity = .awaitingUser(next.requests[0].kind)
      }
    case .turnFailed(let prompt):
      next = apply(.turnEnded, to: next, context: context)
      // Said whatever else waits: nothing goes on until the account is sorted out.
      next.enqueue(
        AgentRequestNotice(
          content: .inTerminal(prompt), reference: AgentToolReference(tool: nil), isShown: true),
        kind: .approval, tool: nil, context: context)
      next.activity = .awaitingUser(next.requests.first?.kind ?? .approval)
    case .turnEnded:
      // A sub-agent in the background can still be waiting on the user once the main turn ends —
      // on a dialog it drew. One announced by its tool and never drawn may never be: a hook of
      // the user's own can stop the tool before either. Should it be drawn after all, its
      // `PermissionRequest` queues it again. A permission the main agent only announced is behind
      // it; a plan, a question or a form may be drawn as the turn ends — Codex's "Implement this
      // plan?" is — and its word read before the end's.
      next.dropAnnouncedRequests { [.network, .permission, .other].contains($0.kind) }
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

  /// The requests not drawn yet that a dialog on screen could be, oldest first.
  func undrawnRequests(matching dialog: AgentDrawnDialog) -> [Int] {
    requests.indices.filter { !requests[$0].isShown && dialog.matches(requests[$0]) }
  }

  /// A request was just reported, at `index`, after the CLI said a dialog was drawn that no
  /// request was known to be: its report may come after its dialog (#273). Only a command quoted
  /// whole arms it (#280); anything less puts the queue in doubt.
  mutating func reportFollows(drawnDialogAt index: Int) {
    guard let dialog = drawnBeforeReport, !requests[index].isShown, dialog.matches(requests[index])
    else { return }
    drawnBeforeReport = nil
    guard dialog.quotesWhole, undrawnRequests(matching: dialog) == [index] else {
      isFirstRequestUncertain = true
      return
    }
    arm(at: index)
  }

  /// Marks drawn the one request a command quoted whole names. Alone in the queue, it is the
  /// dialog on screen whatever doubt came before: Codex settles its requests with no word of which.
  mutating func arm(at index: Int) {
    markDrawn(at: index)
    if heldRequestCount == 1 {
      isFirstRequestUncertain = false
      isTrackLost = false
    }
  }

  /// Marks the request drawn. Reported before it and never drawn, the other permissions were
  /// settled with no dialog — the CLI draws its dialogs in the order it reported them — and
  /// nothing said so.
  mutating func markDrawn(at index: Int) {
    let id = requests[index].id
    let settled = Set(
      requests[..<index].filter {
        !$0.isShown && !$0.content.isAnnouncedOnly && $0.kind == .approval
      }.map(\.id))
    requests[index].isShown = true
    requests.removeAll { settled.contains($0.id) }
    if let first = requests.first, first.id != id, !first.content.isAnnouncedOnly {
      // Another request drawn before it still waits: which dialog is on screen is not known.
      isFirstRequestUncertain = true
    } else if !settled.isEmpty, heldRequestCount == 1, !isTrackLost {
      // Alone once the settled ones are gone, it is the dialog on screen.
      isFirstRequestUncertain = false
    }
  }

  /// Takes away the dialogs only announced (#273), or those of them `which` names: nothing
  /// reports their end, so the next sign of the main agent at work is taken as it.
  mutating func dropAnnouncedRequests(
    _ which: (AgentTerminalPrompt) -> Bool = { _ in true }
  ) {
    func dropped(_ request: AgentRequest) -> Bool {
      guard case .inTerminal(let prompt) = request.content else { return false }
      return which(prompt)
    }
    guard requests.contains(where: dropped) else { return }
    let wasFirst = requests.first.map(dropped) == true
    requests.removeAll(where: dropped)
    if requests.isEmpty {
      clearRequests()
      if case .awaitingUser = activity { activity = .working }
    } else if wasFirst {
      activity = .awaitingUser(requests[0].kind)
    }
  }

  mutating func clearRequests() {
    requests = []
    drawnBeforeReport = nil
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
        content: kind == .approval ? .unreadable(tool: tool) : .elicitation(AgentElicitation()),
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
    if let last = requests.last(where: { !$0.isAsynchronous }),
      abs(context.now.timeIntervalSince(last.receivedAt)) <= 1
    {
      isFirstRequestUncertain = true
    }
    let request = AgentRequest(
      id: id, receivedAt: context.now, kind: kind, content: notice.content,
      reference: notice.reference, isShown: notice.isShown,
      isAsynchronous: notice.isAsynchronous)
    // A question asked without stopping waits behind whatever holds the agent: the dialog on
    // screen is that one's (#273).
    if !request.isAsynchronous, let index = requests.firstIndex(where: \.isAsynchronous) {
      requests.insert(request, at: index)
    } else {
      requests.append(request)
    }
  }

  /// The requests that hold the agent: an asynchronous question waits behind them, and says
  /// nothing of which dialog is on screen (#273).
  var heldRequestCount: Int {
    requests.count { !$0.isAsynchronous }
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
    } else if heldRequestCount == 1, !isTrackLost {
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
        isFirstRequestUncertain = heldRequestCount > 1 || isTrackLost
      }
    } else if let first = requests.first, first.reference.match(reference) == .likely {
      settleFirstRequest(isKnownAnswered: false)
    }
  }
}
