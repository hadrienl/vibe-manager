import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Whether the view follows the end of the conversation, and how much arrived while it did not.
///
/// Pure, so that the rule is tested without a scroll view: following stops as soon as the reader
/// scrolls up, resumes when they come back down, and what arrived meanwhile is counted.
///
/// Read from the scroll geometry rather than from a marker at the end appearing and disappearing:
/// a block arriving pushed such a marker out before the view followed it, which stopped the
/// following while the reader sat at the end, and counted as unseen what they had in front of them.
public struct ConversationScrollState: Hashable, Sendable {
  public private(set) var isFollowing = true
  public private(set) var unseenCount = 0

  /// How far from the end still counts as being there.
  static let bottomTolerance = 24.0

  public init() {}

  /// The view scrolled, or its content changed size.
  ///
  /// - Parameters:
  ///   - distanceToBottom: how much content lies below the visible part.
  ///   - contentMovedDown: how far the content's top moved down since the last reading — positive
  ///     only when the reader scrolled up, since what grows at the end leaves the top in place.
  public mutating func scrolled(distanceToBottom: Double, contentMovedDown: Double) {
    if distanceToBottom <= Self.bottomTolerance {
      isFollowing = true
      unseenCount = 0
    } else if contentMovedDown > 0.5 {
      isFollowing = false
    }
  }

  /// Blocks were added at the end. Returns whether the view should scroll to them.
  public mutating func blocksAppended(_ count: Int) -> Bool {
    guard count > 0 else { return false }
    if isFollowing { return true }
    unseenCount += count
    return false
  }

  /// The reader asked to go to the end.
  public mutating func jumpedToBottom() {
    isFollowing = true
    unseenCount = 0
  }

  /// The reader asked to see something above: the end is no longer followed.
  public mutating func jumpedAway() {
    isFollowing = false
  }
}

/// A sub-agent in the bar over the composer (#180).
public struct SubagentTrayItem: Hashable, Sendable, Identifiable {
  public let call: ToolCall
  /// Ended a moment ago: shown dimmed, then gone.
  public let hasEnded: Bool

  public var id: String { call.callID }
}

/// A prompt sent from the composer, shown until the agent's transcript has it.
/// The request the agent waits on, as the palette of #40 sees it: what may be answered from here.
public struct ConversationRequest: Equatable, Sendable {
  public let request: AgentRequest
  public let answers: Set<AgentAnswerKind>
  public let isSending: Bool

  public init(request: AgentRequest, answers: Set<AgentAnswerKind>, isSending: Bool) {
    self.request = request
    self.answers = answers
    self.isSending = isSending
  }

  public var questions: [AgentQuestion]? {
    if case .questions(let questions) = request.content { return questions }
    return nil
  }

  /// A single question of one choice that takes a free answer: the composer writes it, as its
  /// "Other".
  var takesComposerText: Bool {
    guard let questions, questions.count == 1 else { return false }
    return questions[0].allowsFreeText && !questions[0].allowsMultipleChoices
      && answers.contains(.writeText)
  }

  /// Answered at a click: one question of one choice. Otherwise the choices go together.
  public var answersAtOnce: Bool {
    guard let questions, questions.count == 1 else { return false }
    return !questions[0].allowsMultipleChoices
  }

  func canChoose(in question: AgentQuestion) -> Bool {
    !isSending
      && answers.contains(question.allowsMultipleChoices ? .chooseOptions : .chooseOption)
  }
}

public struct PendingEcho: Identifiable, Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case sending
    /// Nothing came back within ten seconds: the terminal says what happened to it.
    case unconfirmed
  }

  public let id: UUID
  /// The message, or the command without its `!`.
  public let text: String
  public let kind: PromptKind
  public let attachmentCount: Int
  public let sentAt: Date
  /// What ↑ brings back of it into the composer.
  let recallText: String
  /// How many prompts the conversation will hold before this one, those in the transcript and
  /// those sent before it and still coming: it is confirmed by the next. For a command, how many
  /// the transcript held when it was sent: it is confirmed by the same command written after.
  let countAtSend: Int
  /// A command its agent writes to the transcript only once it ended — or once the turn it was
  /// queued behind ended: it is given ten minutes rather than ten seconds before it is said lost,
  /// and no longer holds back the echoes sent after it.
  let waitsForEnd: Bool
  public var state: State

  var confirmationDeadline: Date {
    sentAt.addingTimeInterval(waitsForEnd ? 600 : 10)
  }
}

/// One session's conversation view: what it shows, and what its composer sends (#38).
@MainActor
@Observable
public final class ConversationModel {
  public let sessionID: SessionID
  public private(set) var snapshot = ConversationSnapshot(availability: .loading)
  public private(set) var blocks: [ConversationBlock] = []
  public private(set) var scroll = ConversationScrollState()
  /// Bumped when the view should scroll to the end: a counter, so that twice in a row still moves.
  public private(set) var scrollToBottomRequest = 0
  /// Where the content's top was at the last scroll reading, to tell a scroll up from growth.
  @ObservationIgnored private var lastContentTop: Double?
  /// The view was sent back to the end after landing past it, and has not left that state since.
  @ObservationIgnored private var repositioning = false

  public var activity: AgentActivity? {
    didSet { if activity != oldValue { rebuild() } }
  }
  /// Whether the agent has said it is ready for a prompt. Until its hooks speak, a CLI may still
  /// show a screen of its own — an update offer, a folder to trust — where the Return that sends a
  /// prompt would answer that screen instead: Codex installed an update and quit that way.
  public var isAgentReady = true
  /// Whether the session's process runs. Read through the terminal's own observable state, so
  /// that a view showing the composer follows it.
  @ObservationIgnored public var processRunning: () -> Bool = { false }
  public var isProcessRunning: Bool { processRunning() }
  public var agentName = ""
  public var promptFormat = AgentPromptFormat()
  public var appearance = ConversationAppearance() {
    didSet {
      if appearance.groupsToolCalls != oldValue.groupsToolCalls
        || appearance.showsReasoning != oldValue.showsReasoning
      {
        rebuild()
      }
    }
  }

  // MARK: Composer

  public var draft = ""
  public private(set) var attachments: [URL] = []
  public private(set) var echoes: [PendingEcho] = []
  /// A prompt pasted whose Return is not written yet: another pasted now would join it.
  public private(set) var isSubmitting = false
  /// Writes into the session's terminal, as a keyboard would.
  @ObservationIgnored public var write: (([UInt8]) async -> Void)?
  /// Opens the file panel of Session › Attach Files…, whose choice comes back through `attach`:
  /// one panel for the whole window, since two file importers in one hierarchy do not both show.
  @ObservationIgnored public var chooseFiles: (() -> Void)?
  /// Brings the terminal forward and gives it the keyboard.
  @ObservationIgnored public var showTerminal: (() -> Void)?
  /// Shows a file in the session's web view. `automatically` when the agent just produced it,
  /// rather than the user asking: the web view's own preference then decides whether it comes
  /// forward. `nil` without a web view.
  @ObservationIgnored public var openInWebView: ((URL, _ automatically: Bool) -> Void)?
  /// The images already there when the conversation was first read: only those produced after are
  /// shown on their own.
  @ObservationIgnored private var knownImages: Set<String>?
  /// Restarts the session, from the composer of a session whose agent stopped.
  @ObservationIgnored public var restart: (() -> Void)?
  /// Whether the session can be restarted now: an archived one cannot.
  @ObservationIgnored public var canRestart: () -> Bool = { true }
  /// The first request of the session and how it may be answered, read from the application's
  /// state each time, so that the views follow it.
  @ObservationIgnored public var pendingRequest: () -> ConversationRequest? = { nil }
  /// Types an answer into the session's terminal, as the palette does (#40).
  /// Types an answer into the session's terminal, as the palette does (#40); `true` once it is
  /// typed in full.
  @ObservationIgnored public var answerRequest: ((AgentAnswer, AgentRequestID) async -> Bool)?
  /// The options chosen so far, for a request of several questions answered together.
  public private(set) var questionChoices: [Int: AgentQuestionAnswer] = [:]
  private var choicesRequestID: AgentRequestID?
  @ObservationIgnored private var toggles: [String: Bool] = [:]
  @ObservationIgnored private var followTask: Task<Void, Never>?
  /// A conversation already read stays on screen while its transcripts are read again: what that
  /// reading holds before it ends is only part of it, and showing it would empty the view for as
  /// long as it takes.
  @ObservationIgnored private var isRereading = false
  @ObservationIgnored private var echoTimer: Task<Void, Never>?
  public private(set) var toggleRevision = 0
  /// Bumped to give the composer the keyboard (#105). A counter rather than a flag: the same
  /// request twice in a row must still move the focus twice.
  public private(set) var focusComposerRequest = 0
  /// A request made while the composer was not on screen to take it, consumed once: shown later,
  /// it takes the keyboard then, and never again for having been asked once long ago.
  @ObservationIgnored private var hasPendingFocusRequest = false
  /// Where ↑ and ↓ stand in the messages sent (#123).
  @ObservationIgnored private var historyNavigation = PromptHistoryNavigation()

  public init(sessionID: SessionID) {
    self.sessionID = sessionID
  }

  /// Reads the stream of a `FollowConversation` until it ends or the model is released.
  public func follow(_ snapshots: AsyncStream<ConversationSnapshot>) {
    followTask?.cancel()
    isRereading = snapshot.availability != .loading
    followTask = Task { [weak self] in
      for await snapshot in snapshots {
        self?.received(snapshot)
      }
    }
  }

  func received(_ snapshot: ConversationSnapshot) {
    if isRereading {
      guard snapshot.availability != .loading else { return }
      isRereading = false
    }
    apply(snapshot)
  }

  /// Stops reading the transcripts, and keeps what was read: shown at once when the session comes
  /// back, while `follow` reads them again.
  public func pause() {
    followTask?.cancel()
    followTask = nil
  }

  public func stop() {
    followTask?.cancel()
    followTask = nil
    echoTimer?.cancel()
    startTask?.cancel()
  }

  public func apply(_ snapshot: ConversationSnapshot) {
    self.snapshot = snapshot
    confirmEchoes()
    rebuild()
    showNewImages()
  }

  private func showNewImages() {
    guard snapshot.availability != .loading else { return }
    let images = snapshot.entries.compactMap { entry -> (String, URL)? in
      entry.toolCall?.producedImage.map { (entry.id, $0) }
    }
    guard let known = knownImages else {
      knownImages = Set(images.map(\.0))
      return
    }
    for (id, url) in images where !known.contains(id) {
      openInWebView?(url, true)
    }
    knownImages = known.union(images.map(\.0))
  }

  private func rebuild(lingers: Bool = true) {
    var entries = ConversationEntry.markingPendingPermission(
      snapshot.entries, activity: activity,
      agentID: activity == .awaitingUser(.approval)
        ? pendingRequest()?.request.reference.agentID : nil)
    // A sub-agent whose end never came, in a session whose agent no longer runs, will not end;
    // nor one an earlier process of the agent started, before the session was resumed.
    let isRunning = isProcessRunning
    if isRunning != reportedAgentRunning {
      reportedAgentRunning = isRunning
      processStartedAt = nil
      agentRunningChanged?(isRunning, nil)
      if isRunning { learnProcessStart() }
    }
    if !isRunning, snapshot.availability != .loading {
      entries = Self.settlingSubagents(entries)
    } else if let processStartedAt {
      entries = Self.settlingSubagents(entries, startedBefore: processStartedAt)
    }
    shownEntries = entries
    let rebuilt = displayedBlocks(of: entries)
    let previousIDs = Set(blocks.map(\.id))
    let appended = rebuilt.filter { !previousIDs.contains($0.id) }.count
    let wasEmpty = blocks.isEmpty
    blocks = rebuilt
    updateTray(lingers: lingers)
    if wasEmpty || scroll.blocksAppended(appended) { scrollToBottomRequest += 1 }
  }

  /// The session's process started or ended. Its activity may say nothing of it — an agent idle
  /// while its sub-agents work in the background stays idle when the CLI quits — so the view that
  /// observes the terminal tells: sub-agents that will not end are settled, and the reader told.
  public func processStateChanged() {
    if isProcessRunning != reportedAgentRunning { rebuild() }
  }

  /// Asks when the process started — the kernel knows, whenever the application was opened — and
  /// settles, once it is known, the sub-agents an earlier process left behind.
  private func learnProcessStart() {
    startTask?.cancel()
    startTask = Task { [weak self] in
      guard let self, let date = await self.processStartDate() else { return }
      guard !Task.isCancelled, self.reportedAgentRunning == true else { return }
      self.processStartedAt = date
      self.agentRunningChanged?(true, date)
      // Gone from the bar at once: they did not just end, they ended long ago.
      self.lingering = [:]
      self.rebuild(lingers: false)
    }
  }

  /// Entries laid out as blocks, with the settings of the view: the conversation's, and a
  /// sub-agent's activity alike (#180).
  public func displayedBlocks(of entries: [ConversationEntry]) -> [ConversationBlock] {
    var entries = entries
    if !appearance.showsReasoning {
      entries.removeAll {
        if case .reasoning = $0.content { return true }
        return false
      }
    }
    return ConversationGrouping.blocks(entries, grouping: appearance.groupsToolCalls)
  }

  /// Sub-agents still running, at any depth, marked as stopped — and every call still running in
  /// their activity.
  static func settlingSubagents(_ entries: [ConversationEntry], inside: Bool = false)
    -> [ConversationEntry]
  {
    settling(entries, inside: inside, startedBefore: nil)
  }

  /// Sub-agents still running, at any depth, that started before `date`, settled as above.
  static func settlingSubagents(_ entries: [ConversationEntry], startedBefore date: Date)
    -> [ConversationEntry]
  {
    settling(entries, inside: false, startedBefore: date)
  }

  private static func settling(
    _ entries: [ConversationEntry], inside: Bool, startedBefore date: Date?
  ) -> [ConversationEntry] {
    entries.map { entry in
      guard case .tool(var call) = entry.content, inside || call.kind == .subagent else {
        return entry
      }
      // Only those an earlier process started, when a date is given; the others are looked into.
      let settles =
        inside
        || date.map { date in
          !call.state.isFinished
            && call.subagent?.startedAt.map { SubagentRun.predates($0, process: date) } == true
        } ?? true
      if settles, !call.state.isFinished { call.state = .interrupted }
      if var run = call.subagent, let inner = run.activityEntries {
        run.activity = .read(
          settling(inner, inside: settles, startedBefore: settles ? nil : date))
        call.subagent = run
      }
      var settled = entry
      settled.content = .tool(call)
      return settled
    }
  }

  // MARK: - Sub-agents (#180)

  /// The entries as shown: the permission waited on marked, sub-agents that will not end settled.
  public private(set) var shownEntries: [ConversationEntry] = []
  /// The bar over the composer: the sub-agents running, and those that just ended, for a moment.
  public private(set) var trayItems: [SubagentTrayItem] = []
  /// How long a sub-agent that ended stays in the bar.
  @ObservationIgnored public var trayLinger = Duration.seconds(4)
  /// Tells the reader whether the session's agent runs: a sub-agent whose end never came is not
  /// followed once it does not.
  /// With the instant its process started, once known.
  @ObservationIgnored public var agentRunningChanged: ((Bool, Date?) -> Void)?
  @ObservationIgnored private var reportedAgentRunning: Bool?
  /// When the session's process started, as the kernel says.
  @ObservationIgnored public var processStartDate: () async -> Date? = { nil }
  @ObservationIgnored private var processStartedAt: Date?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var lingering: [String: (call: ToolCall, until: ContinuousClock.Instant)] =
    [:]
  @ObservationIgnored private var lingerTask: Task<Void, Never>?
  /// Tells the reader which sub-agents' transcripts to read besides those running.
  @ObservationIgnored public var unfoldSubagents: ((Set<String>) -> Void)?
  @ObservationIgnored private var unfoldedSubagents: Set<String> = []
  /// The block to bring into view, and a counter: the same one twice in a row still moves.
  public private(set) var revealedBlockID: String?
  public private(set) var revealRequest = 0

  /// - Parameter lingers: whether sub-agents that left the running stay a moment, dimmed.
  private func updateTray(lingers: Bool = true) {
    let running = ConversationEntry.runningSubagents(in: shownEntries)
    let runningIDs = Set(running.map(\.callID))
    let now = ContinuousClock.now
    for item in trayItems
    where lingers && !item.hasEnded && !runningIDs.contains(item.call.callID) {
      let ended = ConversationEntry.subagentCalls([item.call.callID], in: shownEntries).first
      if let ended, ended.state.isFinished {
        lingering[ended.callID] = (ended, now + trayLinger)
      }
    }
    lingering = lingering.filter { $0.value.until > now && !runningIDs.contains($0.key) }
    let items =
      running.map { SubagentTrayItem(call: $0, hasEnded: false) }
      + lingering.values.sorted { $0.until < $1.until }.map {
        SubagentTrayItem(call: $0.call, hasEnded: true)
      }
    if items != trayItems { trayItems = items }
    scheduleLingerEnd()
  }

  private func scheduleLingerEnd() {
    lingerTask?.cancel()
    guard let next = lingering.values.map(\.until).min() else { return }
    lingerTask = Task { [weak self] in
      try? await Task.sleep(until: next, clock: .continuous)
      guard !Task.isCancelled else { return }
      self?.updateTray()
    }
  }

  /// A sub-agent's activity unfolded or folded: its transcript is read while it is unfolded.
  public func setSubagentActivityExpanded(_ isExpanded: Bool, callID: String) {
    setExpanded(isExpanded, for: Self.activityToggleID(callID))
    requestSubagentReading(callID, isExpanded)
  }

  /// A sub-agent whose answer only its own transcript holds — Codex's — is read when its block is
  /// unfolded.
  private func subagentBlockExpanded(_ call: ToolCall, isExpanded: Bool) {
    if isExpanded {
      guard call.subagent?.result == nil, call.state.isFinished else { return }
      requestSubagentReading(call.callID, true)
    } else if !self.isExpanded(id: Self.activityToggleID(call.callID), default: false) {
      requestSubagentReading(call.callID, false)
    }
  }

  private func requestSubagentReading(_ callID: String, _ isRead: Bool) {
    let before = unfoldedSubagents
    if isRead { unfoldedSubagents.insert(callID) } else { unfoldedSubagents.remove(callID) }
    if unfoldedSubagents != before { unfoldSubagents?(unfoldedSubagents) }
  }

  public static func activityToggleID(_ callID: String) -> String { "sub:\(callID):activity" }
  public static func missionToggleID(_ callID: String) -> String { "sub:\(callID):mission" }
  public static func resultToggleID(_ callID: String) -> String { "sub:\(callID):result" }

  /// Shows a sub-agent: the block that holds it is brought into view and unfolded down to it.
  public func revealSubagent(_ callID: String) {
    guard let path = Self.path(to: callID, in: shownEntries), let top = path.first,
      let block = blocks.first(where: { $0.calls.contains { $0.callID == top } })
    else { return }
    if case .subagentGroup = block { setExpanded(true, for: block.id) }
    for ancestor in path.dropLast() {
      setExpanded(true, for: Self.rowToggleID(ancestor))
      setSubagentActivityExpanded(true, callID: ancestor)
    }
    setExpanded(true, for: Self.rowToggleID(callID))
    scroll.jumpedAway()
    revealedBlockID = block.id
    revealRequest += 1
  }

  /// Whether a sub-agent's block is unfolded, wherever it is shown: on its own, as a line of a
  /// group, inside another one's activity. Unfolded unasked when it failed and the settings say so,
  /// or when it waits for the user.
  public func isSubagentExpanded(_ call: ToolCall) -> Bool {
    if let toggled = toggles[Self.rowToggleID(call.callID)] { return toggled }
    if call.state == .awaitingPermission { return true }
    if case .failed = call.state { return appearance.expandsFailures }
    return false
  }

  public func setSubagentExpanded(_ isExpanded: Bool, call: ToolCall) {
    setExpanded(isExpanded, for: Self.rowToggleID(call.callID))
    subagentBlockExpanded(call, isExpanded: isExpanded)
  }

  public static func rowToggleID(_ callID: String) -> String { "sub:\(callID):row" }

  /// The sub-agents from the top of the conversation down to the one asked for.
  static func path(to callID: String, in entries: [ConversationEntry]) -> [String]? {
    for entry in entries {
      guard let call = entry.subagentCall else { continue }
      if call.callID == callID { return [callID] }
      if let inner = call.subagent?.activityEntries, let rest = path(to: callID, in: inner) {
        return [call.callID] + rest
      }
    }
    return nil
  }

  // MARK: - Reading

  public var isReadable: Bool { snapshot.isReadable }

  /// The sub-agent of that identifier, for the palette to say which one asks (#40, #180).
  public func subagent(agentID: String) -> ToolCall? {
    ConversationEntry.subagent(agentID: agentID, in: snapshot.entries)
  }

  /// The call the agent waits on, for the banner: one of a sub-agent's included — the deepest
  /// marked, the sub-agent's own call rather than the sub-agent, when one asks (#180).
  public var pendingCall: ToolCall? {
    guard case .awaitingUser = activity else { return nil }
    return ConversationEntry.allCalls(in: shownEntries).last {
      $0.state == .awaitingPermission || ($0.kind == .question && !$0.state.isFinished)
    }
  }

  /// The call still running, for the activity line. Not a sub-agent: the bar over the composer
  /// shows those, and one in the background runs while the agent does something else.
  public var runningCall: ToolCall? {
    guard activity == .working else { return nil }
    for block in blocks.reversed() {
      switch block {
      case .entry(let entry):
        if let call = entry.toolCall, call.state == .running, call.kind != .subagent {
          return call
        }
      case .toolGroup(_, let calls):
        if let call = calls.last?.toolCall, call.state == .running { return call }
      case .subagentGroup:
        continue
      }
    }
    return nil
  }

  public func isExpanded(_ block: ConversationBlock) -> Bool {
    if let toggled = toggles[block.id] { return toggled }
    switch block {
    case .subagentGroup:
      return true
    case .toolGroup(_, let calls):
      return appearance.expandsFailures
        && calls.contains {
          if case .failed = $0.toolCall?.state { return true }
          return false
        }
    case .entry(let entry):
      guard let call = entry.toolCall else { return false }
      if call.kind.isShownOpen || call.state == .awaitingPermission { return true }
      if case .failed = call.state, appearance.expandsFailures { return true }
      if call.kind == .edit || call.kind == .create { return appearance.expandsEdits }
      return false
    }
  }

  public func setExpanded(_ isExpanded: Bool, for id: String) {
    toggles[id] = isExpanded
    toggleRevision += 1
  }

  public func isExpanded(id: String, default fallback: Bool) -> Bool {
    toggles[id] ?? fallback
  }

  // MARK: - Scrolling

  /// The content's frame in the scroll view's coordinates, and the height the scroll view shows.
  public func scrollGeometryChanged(contentFrame: CGRect, viewportHeight: Double) {
    let movedDown = lastContentTop.map { contentFrame.minY - $0 } ?? 0
    lastContentTop = contentFrame.minY
    var next = scroll
    next.scrolled(
      distanceToBottom: contentFrame.maxY - viewportHeight, contentMovedDown: movedDown)
    // Read on every frame of a scroll: only a change should reach the views that observe it.
    if next != scroll { scroll = next }
    repositionIfPastTheEnd(contentFrame: contentFrame, viewportHeight: viewportHeight)
  }

  /// Rows laid out lazily are measured only when they come into view: sent to the end while they
  /// were estimated taller — often while the conversation sat hidden behind another session — the
  /// scroll view stays past the end of what they really make, and shows nothing until the reader
  /// scrolls. Sent there again, once per such landing, it finds the end now that they are measured.
  private func repositionIfPastTheEnd(contentFrame: CGRect, viewportHeight: Double) {
    let pastTheEnd =
      contentFrame.height > viewportHeight
      && viewportHeight - contentFrame.maxY > viewportHeight / 2
    guard pastTheEnd else {
      repositioning = false
      return
    }
    guard !repositioning else { return }
    repositioning = true
    scrollToBottomRequest += 1
  }

  public func jumpToBottom() {
    scroll.jumpedToBottom()
    scrollToBottomRequest += 1
  }

  // MARK: - Composer

  public enum ComposerState: Hashable, Sendable {
    case ready
    /// The agent asks a question: what is written is its free answer, the "Other" of its options.
    case answeringQuestion
    /// The agent waits for an answer in its terminal: a prompt typed now would be read as one.
    case awaitingAnswer
    /// The agent is starting and has not said it is ready.
    case starting
    case stopped
    /// A provider that cannot be written to from here.
    case unavailable
  }

  public var composerState: ComposerState {
    guard isReadable, write != nil else { return .unavailable }
    guard isProcessRunning else { return .stopped }
    guard isAgentReady else { return .starting }
    if case .awaitingUser = activity {
      return request?.takesComposerText == true ? .answeringQuestion : .awaitingAnswer
    }
    return .ready
  }

  /// Whether the composer can be typed into: a closed one does not take the keyboard.
  public var acceptsInput: Bool {
    composerState == .ready || composerState == .answeringQuestion
  }

  public var canSend: Bool {
    switch composerState {
    case .ready:
      return !isSubmitting && !PromptSubmission(text: draft, attachments: attachments).isEmpty
        && shellHold == nil
    case .answeringQuestion:
      return request?.isSending == false && !freeAnswer.isEmpty
    default:
      return false
    }
  }

  // MARK: - Shell mode

  /// What the composer sends (#188).
  public enum ComposerMode: Hashable, Sendable {
    case message
    /// The draft opens on `!`, and the agent runs it as a shell command.
    case shell
  }

  /// Read from the draft, never kept apart: typing, pasting, erasing the `!` or recalling a
  /// command all give the right mode by themselves.
  public var composerMode: ComposerMode {
    composerState == .ready && promptFormat.shellEntry != nil && draft.hasPrefix("!")
      ? .shell : .message
  }

  /// A draft opening on `!` for an agent that has no shell mode: it goes as a message.
  public var opensOnBangWithoutShellMode: Bool {
    promptFormat.shellEntry == nil && draft.hasPrefix("!")
  }

  /// The name of the folder a command runs in, for the composer to say it.
  public var workingDirectoryName = ""

  /// Why the command written cannot be sent now.
  public enum ShellHold: Hashable, Sendable {
    /// Only the `!`.
    case empty
    /// Files joined before the draft became a command: a command takes none.
    case attachments
    /// The agent works, and would not keep the command for the end of its turn.
    case working
  }

  public var shellHold: ShellHold? {
    guard composerMode == .shell, let shell = promptFormat.shellEntry else { return nil }
    if !attachments.isEmpty { return .attachments }
    if isAgentWorking && !shell.queuesWhileWorking { return .working }
    guard case .shell(let command) = PromptSubmission(text: draft).kind(shell: shell),
      !command.isEmpty
    else { return .empty }
    return nil
  }

  /// Puts a command run before back in the composer, to change it or run it again.
  public func editAgain(_ run: ShellRun) {
    guard composerState == .ready else { return }
    // As if recalled with ↑: the draft put aside comes back with ↓ or Escape.
    draft = historyNavigation.recall(
      PromptHistory.recalled(command: run.command), in: promptHistory, draft: draft)
    requestComposerFocus()
  }

  /// Escape in shell mode: the draft becomes a message again, its text kept. Returns whether the
  /// key was used.
  public func leaveShellMode() -> Bool {
    guard composerState == .ready, composerMode == .shell else { return false }
    draft.removeFirst()
    return true
  }

  private var freeAnswer: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

  // MARK: - Answering

  /// The request, while the agent waits on it and it can be answered from here.
  public var request: ConversationRequest? {
    guard answerRequest != nil, case .awaitingUser = activity else { return nil }
    return pendingRequest()
  }

  /// The request, under the block of the call it is about. A permission names what it would run:
  /// several calls may wait at once, and the one marked as waiting is only the last of them.
  public func request(for call: ToolCall) -> ConversationRequest? {
    guard let request, requestCall(of: request)?.callID == call.callID else { return nil }
    return request
  }

  private func requestCall(of request: ConversationRequest) -> ToolCall? {
    guard case .permission(let permission) = request.request.content,
      let subject = permission.subject
    else { return pendingCall }
    let unfinished = ConversationEntry.allCalls(in: shownEntries)
      .filter { !$0.state.isFinished || $0.state == .awaitingPermission }
    return unfinished.last { Self.isAbout($0, subject) } ?? pendingCall
  }

  /// Whether a permission's subject is what `call` shows.
  static func isAbout(_ call: ToolCall, _ subject: String) -> Bool {
    call.parameter(.command) == subject || call.parameter(.path) == subject
  }

  /// Chooses an option of a question: one question of one choice is answered at once; otherwise
  /// the option is chosen — ticked or unticked, for a question of several choices — and the
  /// answers go together once each question has one.
  public func choose(option: Int, ofQuestion index: Int) {
    guard let request, let questions = request.questions, questions.indices.contains(index),
      request.canChoose(in: questions[index]),
      questions[index].options.indices.contains(option)
    else { return }
    if request.answersAtOnce {
      answer(.answers([.option(option)]))
      return
    }
    if choicesRequestID != request.request.id {
      choicesRequestID = request.request.id
      questionChoices = [:]
    }
    guard questions[index].allowsMultipleChoices else {
      questionChoices[index] = .option(option)
      return
    }
    var ticked: Set<Int> = []
    if case .options(let chosen) = questionChoices[index] { ticked = chosen }
    if ticked.remove(option) == nil { ticked.insert(option) }
    questionChoices[index] = ticked.isEmpty ? nil : .options(ticked)
  }

  public func isChosen(option: Int, ofQuestion index: Int) -> Bool {
    guard choicesRequestID == request?.request.id else { return false }
    switch questionChoices[index] {
    case .option(let chosen): return chosen == option
    case .options(let chosen): return chosen.contains(option)
    case .text, nil: return false
    }
  }

  /// Whether every question has its answer, when they go together.
  public var canSendChoices: Bool {
    guard let request, !request.isSending, !request.answersAtOnce,
      let questions = request.questions, questions.allSatisfy(request.canChoose(in:))
    else { return false }
    return choicesRequestID == request.request.id && questionChoices.count == questions.count
  }

  public func sendChoices() {
    guard canSendChoices, let questions = request?.questions else { return }
    answer(.answers(questions.indices.compactMap { questionChoices[$0] }))
  }

  public func answer(_ answer: AgentAnswer) {
    guard let request, !request.isSending, let answerRequest else { return }
    let id = request.request.id
    Task { _ = await answerRequest(answer, id) }
  }

  public var isAgentWorking: Bool { activity == .working && isProcessRunning }

  public func attach(_ files: [URL]) {
    let writable = files.filter { PathInsertion.isWritablePath($0.path) }
    if composerMode == .shell {
      // A command takes no attachment: the files are named in it, escaped for the shell.
      let paths = writable.map { PathInsertion.shellEscaped($0.path) }
      if !paths.isEmpty {
        let separator = draft == "!" || draft.hasSuffix(" ") ? "" : " "
        draft += separator + paths.joined(separator: " ")
      }
    } else {
      for file in writable where !attachments.contains(file) {
        attachments.append(file)
      }
    }
    requestComposerFocus()
  }

  /// Asks the composer to take the keyboard, now if it is on screen, or as soon as it is.
  public func requestComposerFocus() {
    focusComposerRequest += 1
    hasPendingFocusRequest = true
  }

  func takePendingFocusRequest() -> Bool {
    defer { hasPendingFocusRequest = false }
    return hasPendingFocusRequest
  }

  public func removeAttachment(_ file: URL) {
    attachments.removeAll { $0 == file }
  }

  /// Sends the draft through the terminal. Returns whether it was sent.
  @discardableResult
  public func send() async -> Bool {
    if composerState == .answeringQuestion {
      guard canSend, let request, let answerRequest else { return false }
      // The draft stays until the answer is typed: a request gone meanwhile loses nothing.
      let text = freeAnswer
      guard await answerRequest(.answers([.text(text)]), request.request.id) else { return false }
      if freeAnswer == text { draft = "" }
      return true
    }
    guard canSend, let write else { return false }
    isSubmitting = true
    defer { isSubmitting = false }
    let shell = promptFormat.shellEntry
    let submission = PromptSubmission(text: draft, attachments: attachments)
    let kind = submission.kind(shell: shell)
    let keystrokes = PromptEncoding.keystrokes(
      for: submission, format: promptFormat, whileWorking: isAgentWorking)
    // Prompts still on their way reach the transcript first: this one is confirmed only once
    // they are in too. One the agent never took past ten seconds is no longer waited for.
    // A command is looked for among those written after it was sent; a prompt is confirmed by
    // the count, the prompts still on their way reaching the transcript first.
    let count =
      Self.count(of: kind, in: snapshot.entries)
      + (kind.isShell ? 0 : echoes.filter { $0.state == .sending && !$0.kind.isShell }.count)
    let text: String
    let recallText: String
    switch kind {
    case .shell(let command):
      text = command
      recallText = PromptHistory.recalled(command: command)
    case .message:
      text = PromptEncoding.sanitized(submission.messageText(shell: shell))
      recallText =
        shell == nil ? text : PromptHistory.recalled(message: PromptEncoding.sanitized(draft))
    }
    echoes.append(
      PendingEcho(
        id: UUID(), text: text, kind: kind, attachmentCount: attachments.count,
        sentAt: Date(), recallText: recallText, countAtSend: count,
        // Queued, a command is written once the turn ended, then run.
        waitsForEnd: kind.isShell && (shell?.isRecordedAtStart == false || isAgentWorking),
        state: .sending))
    let submitDelay = promptFormat.delayBeforeSubmit(attachmentCount: attachments.count)
    draft = ""
    attachments = []
    historyNavigation = PromptHistoryNavigation()
    scroll.jumpedToBottom()
    scrollToBottomRequest += 1
    for (index, keys) in keystrokes.writes.enumerated() {
      if index > 0 { try? await Task.sleep(for: keystrokes.delay(before: index)) }
      await write(keys)
    }
    try? await Task.sleep(for: submitDelay)
    await write(keystrokes.submit)
    scheduleEchoCheck()
    return true
  }

  // MARK: - History

  /// The messages sent in this session: those of its transcript, then those on their way to it.
  public var promptHistory: PromptHistory {
    PromptHistory(
      entries: snapshot.entries, pending: echoes.map(\.recallText),
      hasShellMode: promptFormat.shellEntry != nil)
  }

  /// ↑ in the composer: shows the message sent before the one shown, the draft put aside.
  /// Returns whether the key was used; the attachments stay where they are.
  public func recallOlderPrompt() -> Bool {
    guard composerState == .ready,
      let text = historyNavigation.older(in: promptHistory, draft: draft)
    else { return false }
    draft = text
    return true
  }

  /// ↓ in the composer: the next message, and past the most recent, the draft as it was.
  public func recallNewerPrompt() -> Bool {
    guard composerState == .ready,
      let text = historyNavigation.newer(in: promptHistory, draft: draft)
    else { return false }
    draft = text
    return true
  }

  /// Escape in the composer: the draft as it was before ↑, while a message recalled is shown.
  public func cancelPromptRecall() -> Bool {
    guard composerState == .ready,
      let text = historyNavigation.cancel(in: promptHistory, draft: draft)
    else { return false }
    draft = text
    return true
  }

  public func interrupt() async {
    await write?(promptFormat.interruptKey)
  }

  private func confirmEchoes() {
    guard !echoes.isEmpty else { return }
    let prompts = Self.count(of: .message, in: snapshot.entries)
    let commands = snapshot.entries.compactMap(\.shellRun).map(\.command)
    // Each command written confirms the oldest echo of the same command sent before it: one the
    // agent never ran — put back in its prompt by an Escape — holds back no other.
    var claimed = Set<Int>()
    echoes.removeAll { echo in
      guard echo.kind.isShell else { return prompts > echo.countAtSend }
      guard
        let index = commands.indices.first(where: {
          $0 >= echo.countAtSend && !claimed.contains($0) && commands[$0] == echo.text
        })
      else { return false }
      claimed.insert(index)
      return true
    }
  }

  /// The prompts of the conversation, or its shell commands: what confirms an echo of that kind.
  private static func count(of kind: PromptKind, in entries: [ConversationEntry]) -> Int {
    kind.isShell
      ? entries.filter { $0.shellRun != nil }.count : entries.filter(\.isUserPrompt).count
  }

  /// Wakes at the next echo past its wait, marks those past theirs, and waits for the next one.
  private func scheduleEchoCheck() {
    echoTimer?.cancel()
    guard
      let next = echoes.filter({ $0.state == .sending }).map(\.confirmationDeadline).min()
    else { return }
    echoTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
      guard !Task.isCancelled, let self else { return }
      let now = Date()
      for index in self.echoes.indices
      where self.echoes[index].state == .sending && self.echoes[index].confirmationDeadline <= now {
        self.echoes[index].state = .unconfirmed
      }
      self.scheduleEchoCheck()
    }
  }

  public func dismissEcho(_ id: UUID) {
    echoes.removeAll { $0.id == id }
  }
}
