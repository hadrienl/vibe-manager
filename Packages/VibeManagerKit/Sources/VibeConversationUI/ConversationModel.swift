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
  public let text: String
  public let attachmentCount: Int
  public let sentAt: Date
  /// How many prompts the conversation will hold before this one — those in the transcript, and
  /// those sent before it and still coming: it is confirmed by the next.
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
  /// Where the content's top was at the last scroll reading, to tell a scroll up from growth.
  @ObservationIgnored private var lastContentTop: Double?

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
  public var focusComposerRequest = 0

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

  /// The content's frame in the scroll view's coordinates, and the height the scroll view shows.
  public func scrollGeometryChanged(contentFrame: CGRect, viewportHeight: Double) {
    let movedDown = lastContentTop.map { contentFrame.minY - $0 } ?? 0
    lastContentTop = contentFrame.minY
    var next = scroll
    next.scrolled(
      distanceToBottom: contentFrame.maxY - viewportHeight, contentMovedDown: movedDown)
    // Read on every frame of a scroll: only a change should reach the views that observe it.
    if next != scroll { scroll = next }
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

  public var canSend: Bool {
    switch composerState {
    case .ready:
      return !isSubmitting && !PromptSubmission(text: draft, attachments: attachments).isEmpty
    case .answeringQuestion:
      return request?.isSending == false && !freeAnswer.isEmpty
    default:
      return false
    }
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
    let unfinished = blocks.flatMap { block -> [ToolCall] in
      switch block {
      case .entry(let entry): return entry.toolCall.map { [$0] } ?? []
      case .toolGroup(_, let entries): return entries.compactMap(\.toolCall)
      }
    }.filter { !$0.state.isFinished || $0.state == .awaitingPermission }
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
    for file in files where !attachments.contains(file) && PathInsertion.isWritablePath(file.path) {
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
    let submission = PromptSubmission(text: draft, attachments: attachments)
    let keystrokes = PromptEncoding.keystrokes(
      for: submission, format: promptFormat, whileWorking: isAgentWorking)
    // Prompts still on their way reach the transcript first: this one is confirmed only once
    // they are in too. One the agent never took past ten seconds is no longer waited for.
    let promptCount =
      snapshot.entries.filter(\.isUserPrompt).count + echoes.filter { $0.state == .sending }.count
    echoes.append(
      PendingEcho(
        id: UUID(), text: PromptEncoding.sanitized(submission.text),
        attachmentCount: attachments.count,
        sentAt: Date(), promptCountAtSend: promptCount, state: .sending))
    let submitDelay = promptFormat.delayBeforeSubmit(attachmentCount: attachments.count)
    draft = ""
    attachments = []
    scroll.jumpedToBottom()
    scrollToBottomRequest += 1
    await write(keystrokes.paste)
    try? await Task.sleep(for: submitDelay)
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
