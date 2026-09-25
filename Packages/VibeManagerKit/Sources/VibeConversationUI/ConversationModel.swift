import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Whether the view follows the end of the conversation, and how much arrived while it did not.
///
/// Pure, so that the rule is tested without a scroll view: following stops as soon as the reader
/// scrolls up, resumes when they come back down, and what arrived meanwhile is counted.
public struct ConversationScrollState: Hashable, Sendable {
  public private(set) var isFollowing = true
  public private(set) var unseenCount = 0

  public init() {}

  /// The end of the conversation came into view, or left it.
  public mutating func bottomVisibilityChanged(_ isVisible: Bool) {
    isFollowing = isVisible
    if isVisible { unseenCount = 0 }
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
}

/// A prompt sent from the composer, shown until the agent's transcript has it.
public struct PendingEcho: Identifiable, Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case sending
    /// Nothing came back within ten seconds: the terminal says what happened to it.
    case unconfirmed
  }

  public let id: UUID
  public let text: String
  public let attachmentCount: Int
  public let sentAt: Date
  /// How many prompts the conversation held when this one was sent: it is confirmed by the next.
  let promptCountAtSend: Int
  public var state: State
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

  public var activity: AgentActivity? {
    didSet { if activity != oldValue { rebuild() } }
  }
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
  /// Writes into the session's terminal, as a keyboard would.
  @ObservationIgnored public var write: (([UInt8]) async -> Void)?
  /// Brings the terminal forward and gives it the keyboard.
  @ObservationIgnored public var showTerminal: (() -> Void)?
  /// Restarts the session, from the composer of a session whose agent stopped.
  @ObservationIgnored public var restart: (() -> Void)?
  @ObservationIgnored private var toggles: [String: Bool] = [:]
  @ObservationIgnored private var followTask: Task<Void, Never>?
  @ObservationIgnored private var echoTimer: Task<Void, Never>?
  public private(set) var toggleRevision = 0
  public var focusComposerRequest = 0

  public init(sessionID: SessionID) {
    self.sessionID = sessionID
  }

  /// Reads the stream of a `FollowConversation` until it ends or the model is released.
  public func follow(_ snapshots: AsyncStream<ConversationSnapshot>) {
    followTask?.cancel()
    followTask = Task { [weak self] in
      for await snapshot in snapshots {
        self?.apply(snapshot)
      }
    }
  }

  public func stop() {
    followTask?.cancel()
    followTask = nil
    echoTimer?.cancel()
  }

  public func apply(_ snapshot: ConversationSnapshot) {
    self.snapshot = snapshot
    confirmEchoes()
    rebuild()
  }

  private func rebuild() {
    var entries = ConversationEntry.markingPendingPermission(snapshot.entries, activity: activity)
    if !appearance.showsReasoning {
      entries.removeAll {
        if case .reasoning = $0.content { return true }
        return false
      }
    }
    let rebuilt = ConversationGrouping.blocks(entries, grouping: appearance.groupsToolCalls)
    let previousIDs = Set(blocks.map(\.id))
    let appended = rebuilt.filter { !previousIDs.contains($0.id) }.count
    let wasEmpty = blocks.isEmpty
    blocks = rebuilt
    if wasEmpty || scroll.blocksAppended(appended) { scrollToBottomRequest += 1 }
  }

  // MARK: - Reading

  public var isReadable: Bool { snapshot.isReadable }

  /// The call the agent waits on, for the banner.
  public var pendingCall: ToolCall? {
    guard case .awaitingUser = activity else { return nil }
    return blocks.reversed().lazy.compactMap { block -> ToolCall? in
      guard case .entry(let entry) = block, let call = entry.toolCall,
        call.state == .awaitingPermission || (call.kind == .question && !call.state.isFinished)
      else { return nil }
      return call
    }.first
  }

  /// The call still running, for the activity line.
  public var runningCall: ToolCall? {
    guard activity == .working else { return nil }
    for block in blocks.reversed() {
      switch block {
      case .entry(let entry):
        if let call = entry.toolCall, call.state == .running { return call }
      case .toolGroup(_, let calls):
        if let call = calls.last?.toolCall, call.state == .running { return call }
      }
    }
    return nil
  }

  public func isExpanded(_ block: ConversationBlock) -> Bool {
    if let toggled = toggles[block.id] { return toggled }
    switch block {
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

  public func bottomVisibilityChanged(_ isVisible: Bool) {
    scroll.bottomVisibilityChanged(isVisible)
  }

  public func jumpToBottom() {
    scroll.jumpedToBottom()
    scrollToBottomRequest += 1
  }

  // MARK: - Composer

  public enum ComposerState: Hashable, Sendable {
    case ready
    /// The agent waits for an answer in its terminal: a prompt typed now would be read as one.
    case awaitingAnswer
    case stopped
    /// A provider that cannot be written to from here.
    case unavailable
  }

  public var composerState: ComposerState {
    guard isReadable, write != nil else { return .unavailable }
    guard isProcessRunning else { return .stopped }
    if case .awaitingUser = activity { return .awaitingAnswer }
    return .ready
  }

  public var canSend: Bool {
    composerState == .ready
      && !PromptSubmission(text: draft, attachments: attachments).isEmpty
  }

  public var isAgentWorking: Bool { activity == .working && isProcessRunning }

  public func attach(_ files: [URL]) {
    for file in files where !attachments.contains(file) {
      attachments.append(file)
    }
    focusComposerRequest += 1
  }

  public func removeAttachment(_ file: URL) {
    attachments.removeAll { $0 == file }
  }

  /// Sends the draft through the terminal. Returns whether it was sent.
  @discardableResult
  public func send() async -> Bool {
    guard canSend, let write else { return false }
    let submission = PromptSubmission(text: draft, attachments: attachments)
    let keystrokes = PromptEncoding.keystrokes(
      for: submission, format: promptFormat, whileWorking: isAgentWorking)
    let promptCount = snapshot.entries.filter(\.isUserPrompt).count
    echoes.append(
      PendingEcho(
        id: UUID(), text: PromptEncoding.sanitized(submission.text),
        attachmentCount: attachments.count,
        sentAt: Date(), promptCountAtSend: promptCount, state: .sending))
    draft = ""
    attachments = []
    scroll.jumpedToBottom()
    scrollToBottomRequest += 1
    await write(keystrokes.paste)
    try? await Task.sleep(for: promptFormat.submitDelay)
    await write(keystrokes.submit)
    scheduleEchoCheck()
    return true
  }

  public func interrupt() async {
    await write?(promptFormat.interruptKey)
  }

  private func confirmEchoes() {
    guard !echoes.isEmpty else { return }
    let prompts = snapshot.entries.filter(\.isUserPrompt)
    echoes.removeAll { echo in prompts.count > echo.promptCountAtSend }
  }

  private func scheduleEchoCheck() {
    echoTimer?.cancel()
    echoTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled, let self else { return }
      let now = Date()
      for index in self.echoes.indices where now.timeIntervalSince(self.echoes[index].sentAt) >= 10
      {
        self.echoes[index].state = .unconfirmed
      }
    }
  }

  public func dismissEcho(_ id: UUID) {
    echoes.removeAll { $0.id == id }
  }
}
