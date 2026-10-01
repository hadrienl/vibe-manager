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

extension ConversationEntry {
  /// A command of the CLI the user ran — `/mcp`, a skill — as the transcript writes it.
  fileprivate var isCommand: Bool {
    if case .notice(.command) = content { return true }
    return false
  }
}

/// What confirms the echoes: the prompts of the conversation and its shell commands, counted
/// again only among the entries that changed (#250).
struct EchoTallies {
  private(set) var promptIndices: [Int] = []
  private(set) var commands: [(index: Int, command: String)] = []

  mutating func update(_ entries: [ConversationEntry], changedFrom from: Int) {
    while let last = promptIndices.last, last >= from { promptIndices.removeLast() }
    while let last = commands.last, last.index >= from { commands.removeLast() }
    for index in entries.indices.dropFirst(from) {
      let entry = entries[index]
      // A skill or a command sent with `/` is written as a command, not a prompt (#219): it
      // confirms a message as well.
      if entry.isUserPrompt || entry.isCommand { promptIndices.append(index) }
      if let run = entry.shellRun { commands.append((index, run.command)) }
    }
  }

  /// The prompts of the conversation, or its shell commands: what confirms an echo of that kind.
  func count(of kind: PromptKind) -> Int {
    kind.isShell ? commands.count : promptIndices.count
  }
}

/// The blocks the accessibility rotors go through, by their place among the blocks: brought up to
/// date with them, rather than looked for among thousands at each drawing (#250).
public struct ConversationRotor: Equatable, Sendable {
  public private(set) var prompts: [Int] = []
  public private(set) var failures: [Int] = []
  public private(set) var subagents: [Int] = []

  mutating func update(_ blocks: [ConversationBlock], from start: Int) {
    for keyPath in [\Self.prompts, \Self.failures, \Self.subagents] {
      while let last = self[keyPath: keyPath].last, last >= start {
        self[keyPath: keyPath].removeLast()
      }
    }
    for index in blocks.indices.dropFirst(start) {
      let block = blocks[index]
      if Self.isPrompt(block) { prompts.append(index) }
      if Self.isFailure(block) { failures.append(index) }
      if Self.holdsSubagents(block) { subagents.append(index) }
    }
  }

  static func isPrompt(_ block: ConversationBlock) -> Bool {
    if case .entry(let entry) = block { return entry.isUserPrompt }
    return false
  }

  static func holdsSubagents(_ block: ConversationBlock) -> Bool {
    block.calls.contains { $0.kind == .subagent }
  }

  static func isFailure(_ block: ConversationBlock) -> Bool {
    if case .failed = block.toolState { return true }
    return false
  }
}

/// One session's conversation view: what it shows, and what its composer sends (#38).
@MainActor
@Observable
public final class ConversationModel {
  public let sessionID: SessionID
  public private(set) var snapshot = ConversationSnapshot(availability: .loading)
  public private(set) var blocks: [ConversationBlock] = []
  /// The blocks of the accessibility rotors.
  public private(set) var rotor = ConversationRotor()
  public var promptBlocks: [ConversationBlock] { rotor.prompts.map { blocks[$0] } }
  public var failureBlocks: [ConversationBlock] { rotor.failures.map { blocks[$0] } }
  public var subagentBlocks: [ConversationBlock] { rotor.subagents.map { blocks[$0] } }
  public private(set) var scroll = ConversationScrollState()
  /// Bumped when the view should scroll to the end: a counter, so that twice in a row still moves.
  public private(set) var scrollToBottomRequest = 0
  /// Where the content's top was at the last scroll reading, to tell a scroll up from growth.
  @ObservationIgnored private var lastContentTop: Double?
  /// The view was sent back to the end after landing past it, and has not left that state since.
  @ObservationIgnored private var repositioning = false

  public var activity: AgentActivity? {
    didSet {
      guard activity != oldValue else { return }
      rebuild(changedFrom: nil)
      // A skill or a prompt the agent took up: nothing waits in a panel of its terminal.
      if activity == .working { terminalPanel = nil }
      openInitialPanelIfRunning()
    }
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
        rebuild(changedFrom: 0)
      }
    }
  }

  // MARK: Composer

  public var draft = "" {
    didSet { if draft != oldValue { updateCommandSuggestions() } }
  }
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
    isRereading = latestSnapshot.availability != .loading
    // A new stream counts its publications from the start: none says what changed since ours.
    lastRevision = nil
    followTask = Task { [weak self] in
      for await snapshot in snapshots {
        self?.received(snapshot)
      }
    }
  }

  func received(_ snapshot: ConversationSnapshot) {
    if isRereading {
      guard snapshot.availability != .loading else {
        // Passed over: the next one's changes are counted from this one, never seen here.
        lastRevision = nil
        return
      }
      isRereading = false
    }
    apply(snapshot)
  }

  // MARK: - On screen or not (#250)

  /// Whether the conversation is on screen. Hidden, what arrives is kept and nothing is laid out:
  /// only the echoes are confirmed, so that a prompt sent just before switching sessions is not
  /// said lost for nobody having looked.
  @ObservationIgnored public private(set) var isShown = true
  /// Grows at each change of `isShown`, handed to `shownChanged` with it. Shared by every model: a
  /// model made again for a session speaks after the one let go of.
  @ObservationIgnored public private(set) var shownOrder = ConversationModel.nextShownOrder()
  private static var lastShownOrder = 0
  private static func nextShownOrder() -> Int {
    lastShownOrder += 1
    return lastShownOrder
  }
  /// Tells the reader, which publishes less often what nobody sees.
  @ObservationIgnored public var shownChanged: ((_ isShown: Bool, _ order: Int) -> Void)?
  /// The last snapshot received while hidden, laid out once shown.
  @ObservationIgnored private var heldSnapshot: ConversationSnapshot?

  /// The snapshot most recently received, laid out or not.
  private var latestSnapshot: ConversationSnapshot { heldSnapshot ?? snapshot }

  public func setShown(_ shown: Bool) {
    guard shown != isShown else { return }
    isShown = shown
    shownOrder = Self.nextShownOrder()
    shownChanged?(shown, shownOrder)
    guard shown else { return }
    if let held = heldSnapshot {
      heldSnapshot = nil
      snapshot = held
    }
    // Sub-agents that ended while nobody looked leave the bar at once, as they would have done
    // by now on screen.
    if let pending = pendingLayout {
      pendingLayout = (pending.changedFrom, false)
      layOut()
    } else {
      updateTray(lingers: false)
    }
    showNewImages()
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
    // Changed from where the reader says, when this follows the last one received; otherwise
    // from the start, which is never wrong (#250).
    let changedFrom =
      lastRevision.map { snapshot.revision == $0 + 1 } == true ? snapshot.unchangedPrefix : 0
    lastRevision = snapshot.revision
    echoTallies.update(snapshot.entries, changedFrom: changedFrom)
    confirmEchoes()
    imagesChangedFrom = min(imagesChangedFrom ?? .max, changedFrom)
    guard isShown else {
      heldSnapshot = snapshot
      rebuild(changedFrom: changedFrom)
      Signposts.signposter.emitEvent("conversation.hiddenSnapshot")
      return
    }
    self.snapshot = snapshot
    rebuild(changedFrom: changedFrom)
    showNewImages()
  }

  private func showNewImages() {
    guard snapshot.availability != .loading, let changedFrom = imagesChangedFrom else { return }
    imagesChangedFrom = nil
    // Only those among the entries that changed: the others were looked at already.
    let entries = snapshot.entries
    let start = knownImages == nil ? 0 : min(changedFrom, entries.count)
    let images = entries[start...].compactMap { entry -> (String, URL)? in
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

  // MARK: - Layout (#250)

  /// What the layout of the entries depends on besides them: when one changes, everything is laid
  /// out again.
  struct LayoutInputs: Equatable {
    enum Settling: Equatable {
      case untouched
      /// Every sub-agent still running: the agent no longer runs.
      case all
      /// Those an earlier process of the agent started.
      case startedBefore(Date)
    }
    var settling: Settling
    var groupsToolCalls: Bool
    var showsReasoning: Bool
  }

  /// What was laid out for the last snapshot, to lay out the next one from where it changed.
  struct LayoutState {
    var inputs: LayoutInputs?
    /// The entry marked as waiting for a permission.
    var markedIndex: Int?
    /// The index in `shownEntries` of each block's first entry.
    var starts: [Int] = []
    /// The indices in `shownEntries` of the sub-agents started by the agent itself.
    var subagentIndices: [Int] = []
  }

  /// How much one layout did, counted rather than timed: a count does not depend on how busy the
  /// machine is, so that tests can hold it to a bound.
  struct LayoutWork: Equatable {
    var entries = 0
    var blocks = 0
  }

  /// The entries laid out again from there at the next layout, and whether sub-agents that left
  /// the running linger in the bar; `nil` when nothing waits.
  @ObservationIgnored private var pendingLayout: (changedFrom: Int, lingers: Bool)?
  @ObservationIgnored private var layoutState = LayoutState()
  /// The last publication received from the reader, `nil` when the next cannot follow it.
  @ObservationIgnored private var lastRevision: Int?
  /// The entries from which the images produced were not looked at yet.
  @ObservationIgnored private var imagesChangedFrom: Int?
  @ObservationIgnored private var echoTallies = EchoTallies()
  @ObservationIgnored private(set) var layoutCount = 0
  @ObservationIgnored private(set) var lastLayoutWork = LayoutWork()

  /// Lays out again what changed — the entries from `changedFrom`, nothing when `nil` — now if
  /// the conversation is on screen, once it is otherwise.
  private func rebuild(changedFrom: Int?, lingers: Bool = true) {
    reportProcessState()
    let from = changedFrom ?? shownEntries.count
    pendingLayout = (
      min(pendingLayout?.changedFrom ?? .max, from), (pendingLayout?.lingers ?? true) && lingers
    )
    guard isShown else {
      updateAnnouncedCall()
      return
    }
    layOut()
  }

  /// Tells the reader whether the session's agent runs: a sub-agent whose end never came, in a
  /// session whose agent no longer runs, will not end; nor one an earlier process of the agent
  /// started, before the session was resumed.
  private func reportProcessState() {
    let isRunning = isProcessRunning
    guard isRunning != reportedAgentRunning else { return }
    reportedAgentRunning = isRunning
    processStartedAt = nil
    agentRunningChanged?(isRunning, nil)
    if isRunning { learnProcessStart() }
  }

  private func layOut() {
    guard let pending = pendingLayout else { return }
    pendingLayout = nil
    Signposts.interval("conversation.apply") { layOut(changedFrom: pending.changedFrom) }
    updateTray(lingers: pending.lingers)
    updateAnnouncedCall()
  }

  /// The entries as shown, then their blocks, from the first that may differ: the permission
  /// waited on marked, sub-agents that will not end settled, tools of a family grouped.
  private func layOut(changedFrom: Int) {
    reportProcessState()
    let entries = snapshot.entries
    let inputs = LayoutInputs(
      settling: !isProcessRunning && snapshot.availability != .loading
        ? .all : processStartedAt.map(LayoutInputs.Settling.startedBefore) ?? .untouched,
      groupsToolCalls: appearance.groupsToolCalls, showsReasoning: appearance.showsReasoning)
    let mark = ConversationEntry.pendingPermissionMark(
      entries, activity: activity,
      agentID: activity == .awaitingUser(.approval)
        ? pendingRequest()?.request.reference.agentID : nil)
    var from = min(changedFrom, entries.count, shownEntries.count)
    if inputs != layoutState.inputs { from = 0 }
    // The entry marked, or no longer marked, is laid out again wherever it is.
    if let marked = layoutState.markedIndex { from = min(from, marked) }
    if let mark { from = min(from, mark.index) }

    var changed = Array(entries[from...])
    if let mark { changed[mark.index - from] = mark.entry }
    switch inputs.settling {
    case .untouched: break
    case .all: changed = Self.settlingSubagents(changed)
    case .startedBefore(let date): changed = Self.settlingSubagents(changed, startedBefore: date)
    }
    shownEntries.replaceSubrange(from..., with: changed)
    layoutState.inputs = inputs
    layoutState.markedIndex = mark?.index
    while let last = layoutState.subagentIndices.last, last >= from {
      layoutState.subagentIndices.removeLast()
    }
    layoutState.subagentIndices += shownEntries.indices.dropFirst(from).filter {
      shownEntries[$0].subagentCall != nil
    }

    // The blocks before the one to start from stay as they are, with their views.
    let restart =
      from == 0
      ? 0
      : ConversationGrouping.restartBlock(
        starts: layoutState.starts, blocks: blocks, changedFrom: from)
    var rebuilt = Array(blocks[..<restart])
    var starts = Array(layoutState.starts[..<restart])
    let showsReasoning = inputs.showsReasoning
    ConversationGrouping.group(
      shownEntries, from: restart == 0 ? 0 : layoutState.starts[restart],
      grouping: inputs.groupsToolCalls,
      includes: { entry in
        if !showsReasoning, case .reasoning = entry.content { return false }
        return true
      },
      into: &rebuilt, starts: &starts)
    // New blocks can only be among those laid out again.
    let previousIDs = Set(blocks[restart...].map(\.id))
    let appended = rebuilt[restart...].filter { !previousIDs.contains($0.id) }.count
    let wasEmpty = blocks.isEmpty
    blocks = rebuilt
    layoutState.starts = starts
    rotor.update(blocks, from: restart)
    layoutCount += 1
    lastLayoutWork = LayoutWork(entries: changed.count, blocks: rebuilt.count - restart)
    if wasEmpty || scroll.blocksAppended(appended) { scrollToBottomRequest += 1 }
    #if DEBUG
      verifyLayout()
    #endif
  }

  #if DEBUG
    /// With `VIBE_VERIFY_CONVERSATION=1`, one layout in fifty is done again in full and compared.
    private func verifyLayout() {
      guard ProcessInfo.processInfo.environment["VIBE_VERIFY_CONVERSATION"] == "1",
        layoutCount % 50 == 0
      else { return }
      var entries = ConversationEntry.markingPendingPermission(
        snapshot.entries, activity: activity,
        agentID: activity == .awaitingUser(.approval)
          ? pendingRequest()?.request.reference.agentID : nil)
      switch layoutState.inputs?.settling {
      case .all: entries = Self.settlingSubagents(entries)
      case .startedBefore(let date): entries = Self.settlingSubagents(entries, startedBefore: date)
      case .untouched, nil: break
      }
      assert(entries == shownEntries, "Entries laid out from where they changed differ")
      assert(
        displayedBlocks(of: entries) == blocks, "Blocks laid out from where they changed differ")
    }
  #endif

  /// The session's process started or ended. Its activity may say nothing of it — an agent idle
  /// while its sub-agents work in the background stays idle when the CLI quits — so the view that
  /// observes the terminal tells: sub-agents that will not end are settled, and the reader told.
  public func processStateChanged() {
    if isProcessRunning != reportedAgentRunning { rebuild(changedFrom: nil) }
    if !isProcessRunning { terminalPanel = nil }
    openInitialPanelIfRunning()
  }

  /// Asks when the process started — the kernel knows, whenever the application was opened — and
  /// settles, once it is known, the sub-agents an earlier process left behind.
  private func learnProcessStart() {
    startTask?.cancel()
    startTask = Task { [weak self] in
      // A terminal still starting has no process to date yet: asked again until it has, for as long
      // as the agent is said to run.
      var date: Date?
      while !Task.isCancelled, self?.reportedAgentRunning == true {
        date = await self?.processStartDate()
        if date != nil { break }
        try? await Task.sleep(for: Self.processStartRetry)
      }
      guard let self, let date, !Task.isCancelled, self.reportedAgentRunning == true else {
        return
      }
      self.processStartedAt = date
      self.agentRunningChanged?(true, date)
      // Gone from the bar at once: they did not just end, they ended long ago.
      self.lingering = [:]
      self.rebuild(changedFrom: nil, lingers: false)
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
  /// How often a process that cannot be dated yet is asked again.
  static let processStartRetry = Duration.milliseconds(500)
  @ObservationIgnored private var lingering:
    [String: (call: ToolCall, until: ContinuousClock.Instant)] =
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
    // Hidden, the bar waits for the conversation to come back, and is brought up to date then.
    guard isShown else { return }
    // Only the sub-agents the agent started, and theirs: not the thousands of other entries.
    let subagents = layoutState.subagentIndices.map { shownEntries[$0] }
    let running = ConversationEntry.runningSubagents(in: subagents)
    let runningIDs = Set(running.map(\.callID))
    let now = ContinuousClock.now
    for item in trayItems
    where lingers && !item.hasEnded && !runningIDs.contains(item.call.callID) {
      let ended = ConversationEntry.subagentCalls([item.call.callID], in: subagents).first
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
    // Asked of a conversation in the background too: what was received, laid out or not.
    ConversationEntry.subagent(agentID: agentID, in: latestSnapshot.entries)
  }

  /// The call the agent waits on, for the banner: one of a sub-agent's included — the deepest
  /// marked, the sub-agent's own call rather than the sub-agent, when one asks (#180).
  public var pendingCall: ToolCall? {
    guard case .awaitingUser = activity else { return nil }
    return Self.waitedCall(in: shownEntries)
  }

  private static func waitedCall(in entries: [ConversationEntry]) -> ToolCall? {
    ConversationEntry.allCalls(in: entries).last {
      $0.state == .awaitingPermission || ($0.kind == .question && !$0.state.isFinished)
    }
  }

  /// The call the agent waits on, for VoiceOver to say: taken from what was received, laid out or
  /// not, so that a conversation hidden still announces a permission or a question, as it did
  /// before only the one on screen was laid out (#250). The same as `pendingCall` once shown.
  public private(set) var announcedCallID: String?

  private func updateAnnouncedCall() {
    let id: String?
    if isShown {
      id = pendingCall?.callID
    } else if case .awaitingUser = activity {
      var entries = latestSnapshot.entries
      let mark = ConversationEntry.pendingPermissionMark(
        entries, activity: activity,
        agentID: activity == .awaitingUser(.approval)
          ? pendingRequest()?.request.reference.agentID : nil)
      if let mark { entries[mark.index] = mark.entry }
      id = Self.waitedCall(in: entries)?.callID
    } else {
      id = nil
    }
    if id != announcedCallID { announcedCallID = id }
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
    showRecalled(
      historyNavigation.recall(
        PromptHistory.recalled(command: run.command), in: promptHistory, draft: draft))
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

  /// Joins files to the draft. `focusing`: the composer takes the keyboard — not for a message
  /// put there for the user (#291).
  public func attach(_ files: [URL], focusing: Bool = true) {
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
    if focusing { requestComposerFocus() }
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
      echoTallies.count(of: kind)
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
    let echoID = UUID()
    // A command of the CLI — `/mcp` — may open a panel of its terminal, and be written to the
    // transcript only once the panel is closed: it is waited for as long (#219).
    let opensPanel = kind == .message && text.hasPrefix("/") && !isAgentWorking
    echoes.append(
      PendingEcho(
        id: echoID, text: text, kind: kind, attachmentCount: attachments.count,
        sentAt: Date(), recallText: recallText, countAtSend: count,
        // Queued, a command is written once the turn ended, then run.
        waitsForEnd: opensPanel
          || kind.isShell && (shell?.isRecordedAtStart == false || isAgentWorking),
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
    if opensPanel { watchForTerminalPanel(echoID, command: text) }
    return true
  }

  // MARK: - A panel of the agent's terminal

  /// A command sent from the composer that the agent answers with a panel of its terminal — `/mcp`,
  /// `/model` without an argument — rather than in its transcript (#219). The terminal is then
  /// shown in the conversation, live, until the transcript says the command ran, the agent starts
  /// working, or the user closes it.
  public struct TerminalPanel: Hashable, Sendable {
    /// The echo of the command sent from the composer; `nil` for the initial prompt.
    public let echoID: UUID?
    /// `/mcp`, without what follows it.
    public let command: String
  }

  public private(set) var terminalPanel: TerminalPanel? {
    didSet {
      guard terminalPanel != oldValue else { return }
      panelSeen = false
      panelGone?.cancel()
      panelGone = nil
      panelFirstSight?.cancel()
      panelFirstSight = nil
    }
  }
  @ObservationIgnored private var panelWatch: Task<Void, Never>?
  /// Bumped for the block's terminal to take the keyboard: once the composer has let it go —
  /// SwiftUI gives it back to the field it last focused, after the terminal took it.
  public private(set) var terminalPanelFocusRequest = 0
  /// Whether the block's terminal has shown the panel: from then on, the panel gone closes it.
  @ObservationIgnored private var panelSeen = false
  @ObservationIgnored private var panelGone: Task<Void, Never>?
  @ObservationIgnored private var panelFirstSight: Task<Void, Never>?
  /// A session started on a command (#219): its panel is looked for while the agent runs and does
  /// not work — starting, an agent may seem to work or stop for a moment — until it is seen, or
  /// until `initialCommandDeadline`.
  @ObservationIgnored private var initialCommand: String?
  @ObservationIgnored private var initialCommandDeadline = Date.distantPast
  /// How long a session started on a command looks for its panel.
  static let initialCommandWindow: TimeInterval = 30
  /// How long a block waits to see a panel before it takes the command for one that opened none.
  static let panelFirstSightLimit = Duration.seconds(4)
  /// An agent starting takes longer to draw its first screen.
  static let initialPanelFirstSightLimit = Duration.seconds(10)
  /// A panel's hint gone this long is the panel closed, not a screen being redrawn — a new size
  /// makes the program draw it again.
  static let panelGoneDelay = Duration.milliseconds(800)
  /// How long a command may take to be written before its panel is looked for: a command that
  /// runs at once — `/compact`, a skill — never shows one.
  static let terminalPanelDelay = Duration.milliseconds(600)

  private func watchForTerminalPanel(_ id: UUID, command text: String) {
    panelWatch?.cancel()
    let command = String(text.prefix { !$0.isWhitespace })
    panelWatch = Task { [weak self] in
      try? await Task.sleep(for: Self.terminalPanelDelay)
      guard !Task.isCancelled, let self, !self.isAgentWorking, self.isProcessRunning,
        self.echoes.contains(where: { $0.id == id && $0.state == .sending })
      else { return }
      self.openTerminalPanel(TerminalPanel(echoID: id, command: command))
    }
  }

  private func openTerminalPanel(_ panel: TerminalPanel, firstSight: Duration? = nil) {
    defer {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard let self, self.terminalPanel == panel else { return }
        self.terminalPanelFocusRequest += 1
      }
    }
    terminalPanel = panel
    // A command that opened no panel after all: the block goes by itself.
    panelFirstSight = Task { [weak self] in
      try? await Task.sleep(for: firstSight ?? Self.panelFirstSightLimit)
      guard !Task.isCancelled, let self, self.terminalPanel == panel, !self.panelSeen else {
        return
      }
      // No panel after all: a session started on a command that opened none.
      if panel.echoID == nil { self.initialCommand = nil }
      self.endTerminalPanel()
    }
  }

  /// A session started on a command of its CLI — its initial prompt — may open a panel as well:
  /// looked for once the agent runs.
  public func expectTerminalPanel(forInitialPrompt prompt: String) {
    let command = String(prompt.prefix { !$0.isWhitespace })
    guard command.hasPrefix("/"), command.count > 1 else { return }
    initialCommand = command
    initialCommandDeadline = Date().addingTimeInterval(Self.initialCommandWindow)
    openInitialPanelIfRunning()
  }

  private func openInitialPanelIfRunning() {
    guard let command = initialCommand else { return }
    guard Date() < initialCommandDeadline else {
      initialCommand = nil
      return
    }
    guard isProcessRunning, !isAgentWorking, terminalPanel == nil else { return }
    openTerminalPanel(
      TerminalPanel(echoID: nil, command: command), firstSight: Self.initialPanelFirstSightLimit)
  }

  /// What the block's terminal shows, as it changes: the panel seen, then gone, closes the block
  /// — the CLI writes nothing of a panel closed with Escape.
  public func terminalScreenChanged(_ screen: String) {
    guard terminalPanel != nil else { return }
    if AgentPanelRecognition.showsPanel(screen: screen) {
      panelSeen = true
      // Found: a session started on a command looks for it no more.
      if terminalPanel?.echoID == nil { initialCommand = nil }
      panelGone?.cancel()
      panelGone = nil
    } else if panelSeen, panelGone == nil {
      let panel = terminalPanel
      panelGone = Task { [weak self] in
        try? await Task.sleep(for: Self.panelGoneDelay)
        guard !Task.isCancelled, let self, self.terminalPanel == panel else { return }
        self.endTerminalPanel()
      }
    }
  }

  /// The panel is gone from the terminal: the block goes, and the keyboard back to the composer.
  private func endTerminalPanel() {
    guard let panel = terminalPanel else { return }
    terminalPanel = nil
    if let echo = panel.echoID { dismissEcho(echo) }
    requestComposerFocus()
  }

  /// Closes the panel from the conversation: Escape, as in the terminal, then the block goes. The
  /// command is no longer waited for.
  public func closeTerminalPanel() async {
    guard let panel = terminalPanel else { return }
    terminalPanel = nil
    if let echo = panel.echoID { dismissEcho(echo) }
    await write?(promptFormat.interruptKey)
    requestComposerFocus()
  }

  /// The block goes once its command is no longer waited for.
  private func settleTerminalPanel() {
    guard let panel = terminalPanel, let echo = panel.echoID,
      !echoes.contains(where: { $0.id == echo })
    else { return }
    terminalPanel = nil
    requestComposerFocus()
  }

  // MARK: - Skills and commands

  /// The list under a `/` typed first in the composer (#219).
  public let commands = ComposerCommands()

  /// Reads the skills and commands of the session's agent: the list kept, read again when it is
  /// stale. `nil` for an agent that cannot list them — `/` is then text.
  public var readCommands: (() async -> AgentCommandIndex?)? {
    get { commands.read }
    set { commands.read = newValue }
  }
  public var commandIndex: AgentCommandIndex { commands.index }
  public var commandSuggestions: [AgentCommandMatch]? { commands.suggestions }
  public var selectedCommandIndex: Int { commands.selectedIndex }

  public func refreshCommands() { commands.refresh() }

  private func updateCommandSuggestions() {
    commands.update(text: draft, isEnabled: composerState == .ready)
  }

  /// Whether the list is on screen: while a message can be written.
  public var showsCommandSuggestions: Bool {
    commands.isShowing && composerState == .ready
  }

  /// ↑ or ↓ while the list is open. Returns whether the key was used.
  public func moveCommandSelection(by offset: Int) -> Bool {
    showsCommandSuggestions && commands.moveSelection(by: offset)
  }

  /// ⇥ or ↩ while the list is open: the entry selected replaces what was typed. Returns whether
  /// one was inserted. ↩ inserts only to complete a name begun: with nothing matching, a match
  /// found by its description only, or a name typed in full, it sends the text as it is.
  public func insertSelectedCommand(onReturn: Bool = false) -> Bool {
    guard showsCommandSuggestions, let command = commands.selectedCommand else { return false }
    guard !onReturn || commands.returnInserts else { return false }
    insertCommand(command)
    return true
  }

  public func insertCommand(_ command: AgentCommand) {
    guard composerState == .ready else { return }
    draft = commands.inserting(command)
  }

  /// Escape while the list is open: it closes, the draft left as it is.
  public func dismissCommandSuggestions() -> Bool {
    showsCommandSuggestions && commands.dismiss()
  }

  /// The command the draft opens on, as inserted from the list: shown as a token.
  public var insertedInvocation: String? { commands.insertedInvocation }

  /// What the command inserted expects, dimmed after it until something is typed.
  public var pendingArgumentHint: String? { commands.pendingArgumentHint }

  /// A message recalled from the history is shown without its list: ↑ and ↓ keep walking the
  /// history.
  private func showRecalled(_ text: String) {
    commands.willShowRecalled(text)
    draft = text
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
    showRecalled(text)
    return true
  }

  /// ↓ in the composer: the next message, and past the most recent, the draft as it was.
  public func recallNewerPrompt() -> Bool {
    guard composerState == .ready,
      let text = historyNavigation.newer(in: promptHistory, draft: draft)
    else { return false }
    showRecalled(text)
    return true
  }

  /// Escape in the composer: the draft as it was before ↑, while a message recalled is shown.
  public func cancelPromptRecall() -> Bool {
    guard composerState == .ready,
      let text = historyNavigation.cancel(in: promptHistory, draft: draft)
    else { return false }
    showRecalled(text)
    return true
  }

  public func interrupt() async {
    await write?(promptFormat.interruptKey)
  }

  private func confirmEchoes() {
    guard !echoes.isEmpty else { return }
    let prompts = echoTallies.count(of: .message)
    let commands = echoTallies.commands.map(\.command)
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
    settleTerminalPanel()
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
    settleTerminalPanel()
  }
}
