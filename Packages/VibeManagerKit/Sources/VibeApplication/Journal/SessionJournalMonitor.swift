import Foundation
import VibeDomain

/// A session's journal changed.
public struct SessionJournalUpdate: Hashable, Sendable {
  public let sessionID: SessionID
  public let journal: SessionJournal
  /// A summary pass is under way.
  public let isSummarizing: Bool

  public init(sessionID: SessionID, journal: SessionJournal, isSummarizing: Bool) {
    self.sessionID = sessionID
    self.journal = journal
    self.isSummarizing = isSummarizing
  }
}

/// Keeps the journal of every active session (#36): the resources as soon as a line names them,
/// the summary once a turn has ended.
///
/// Every active session, not only the one on screen — a session in the background must summarize
/// itself — through one watch of the agents' transcript folders, comparing the names of what moved
/// with the sessions followed. Only the files that grew are read, from where they were left.
///
/// Nothing here goes through the terminal, the terminal host or the main thread: a summary is an
/// ordinary process of the session's CLI, and only a changed journal is published.
public actor SessionJournalMonitor {
  public struct Timing: Sendable {
    /// Calm after a turn ends before a pass starts: a turn followed by another is one pass.
    public var quiet: Duration
    /// At most one pass per session in this time.
    public var minimumInterval: Duration
    /// After a failed pass, the next attempts; then only the next turn tries again.
    public var retries: [Duration]
    /// Events of the file system gathered before reading.
    public var readDelay: Duration
    /// Changes gathered before the journal is written.
    public var saveDelay: Duration

    public init(
      quiet: Duration = .seconds(10), minimumInterval: Duration = .seconds(300),
      retries: [Duration] = [.seconds(60), .seconds(300), .seconds(900)],
      readDelay: Duration = .milliseconds(500), saveDelay: Duration = .seconds(2)
    ) {
      self.quiet = quiet
      self.minimumInterval = minimumInterval
      self.retries = retries
      self.readDelay = readDelay
      self.saveDelay = saveDelay
    }
  }

  private struct Followed {
    var session: WorkSession
    var journal: SessionJournal
    /// Still in the store's active sessions; false once it stopped, true again if it restarts.
    var isActive = true
    var isReading = false
    var readAgain = false
    var scheduledPass: Task<Void, Never>?
    var runningPass: Task<Void, Never>?
    var passAgain = false
    var lastPassAt: Date?
    var failures = 0
    var pendingSave: Task<Void, Never>?
  }

  private let store: any SessionJournalStore
  private let reader: any SessionJournalReading
  private let resolution: ResourceResolution
  private let summarizers: any SessionSummarizerResolving
  private let events: (any FileChangeObserving)?
  private let repository: (any SessionRepository)?
  private let timing: Timing
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let language: String
  private let maximumConcurrentPasses: Int

  private var followed: [SessionID: Followed] = [:]
  /// Sessions no longer active, being read and summarized one last time.
  private var finishing: [SessionID: Task<Void, Never>] = [:]
  private var continuations: [UUID: AsyncStream<SessionJournalUpdate>.Continuation] = [:]
  private var watchedDirectories: [String] = []
  private var watchTask: Task<Void, Never>?
  private var pendingReads: Set<SessionID> = []
  private var readTask: Task<Void, Never>?
  private var runningPasses = 0
  private var passWaiters: [CheckedContinuation<Void, Never>] = []
  private var summariesEnabled: Bool
  private var isStopped = false

  public init(
    store: any SessionJournalStore,
    reader: any SessionJournalReading,
    repositories: any RepositoryIdentityResolving,
    summarizers: any SessionSummarizerResolving,
    events: (any FileChangeObserving)? = nil,
    repository: (any SessionRepository)? = nil,
    summariesEnabled: Bool = true,
    timing: Timing = Timing(),
    maximumConcurrentPasses: Int = 2,
    language: String = Locale.preferredLanguages.first ?? "en",
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.store = store
    self.reader = reader
    resolution = ResourceResolution(repositories: repositories)
    self.summarizers = summarizers
    self.events = events
    self.repository = repository
    self.summariesEnabled = summariesEnabled
    self.timing = timing
    self.maximumConcurrentPasses = maximumConcurrentPasses
    self.language = language
    self.now = now
    self.sleep = sleep
  }

  // MARK: - Subscribing

  public func updates() -> AsyncStream<SessionJournalUpdate> {
    let (stream, continuation) = AsyncStream.makeStream(of: SessionJournalUpdate.self)
    let key = UUID()
    continuations[key] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(key) }
    }
    return stream
  }

  private func unsubscribe(_ key: UUID) {
    continuations[key] = nil
  }

  private func publish(_ id: SessionID) {
    guard let state = followed[id] else { return }
    publish(id, state.journal, isSummarizing: state.runningPass != nil)
  }

  private func publish(_ id: SessionID, _ journal: SessionJournal, isSummarizing: Bool) {
    let update = SessionJournalUpdate(
      sessionID: id, journal: journal, isSummarizing: isSummarizing)
    for continuation in continuations.values { continuation.yield(update) }
  }

  // MARK: - Reading a journal

  /// The journal of any session, active or archived. `nil` when it has none.
  public func journal(for id: SessionID) async -> SessionJournal? {
    if let state = followed[id] { return state.journal }
    return try? await store.journal(for: id)
  }

  // MARK: - Which sessions

  /// The sessions as the store has them now. The active ones are followed; one that stopped being
  /// active is read and summarized a last time, without waiting for the interval.
  public func track(_ sessions: [WorkSession]) async {
    guard !isStopped else { return }
    let active = sessions.filter { $0.status == .active }
    let activeIDs = Set(active.map(\.id))
    for id in followed.keys where !activeIDs.contains(id) {
      followed[id]?.isActive = false
      finish(id)
    }
    for session in active {
      if var state = followed[session.id] {
        if state.session.agent?.providerID != session.agent?.providerID,
          case .unavailable = state.journal.summary
        {
          // Another agent may well be able to.
          state.journal.summary = .ready
        }
        state.session = session
        state.isActive = true
        followed[session.id] = state
        continue
      }
      var journal = (try? await store.journal(for: session.id)) ?? SessionJournal()
      // Each launch asks again whether the agent can summarize: it may have been updated.
      if case .unavailable = journal.summary { journal.summary = .ready }
      guard followed[session.id] == nil, !isStopped else { continue }
      followed[session.id] = Followed(session: session, journal: journal)
      publish(session.id)
      requestRead(session.id)
      // Turns left pending by the last launch — quit during a pass, or after one failed.
      schedulePass(session.id)
    }
    await refreshWatch()
  }

  /// Summaries on or off. Off, no pass starts; the resources are still read.
  public func setSummariesEnabled(_ enabled: Bool) {
    summariesEnabled = enabled
    guard enabled else {
      for id in followed.keys {
        followed[id]?.scheduledPass?.cancel()
        followed[id]?.scheduledPass = nil
      }
      return
    }
    for id in followed.keys { schedulePass(id) }
  }

  /// Retry: a pass now, whatever the interval says.
  public func retry(_ id: SessionID) {
    guard var state = followed[id] else { return }
    state.failures = 0
    if case .unavailable = state.journal.summary { state.journal.summary = .ready }
    followed[id] = state
    schedulePass(id, after: .zero)
  }

  /// Reads everything once more: the application came back to the front, events may have been
  /// missed.
  public func refresh() {
    for id in followed.keys { requestRead(id) }
  }

  /// Stops for good: passes under way are called off — their process killed — and what changed is
  /// written. The turns they were summarizing stay pending for the next launch.
  public func stop() async {
    isStopped = true
    watchTask?.cancel()
    watchTask = nil
    readTask?.cancel()
    for (id, state) in followed {
      state.scheduledPass?.cancel()
      state.runningPass?.cancel()
      state.pendingSave?.cancel()
      try? await store.save(state.journal, for: id)
    }
    for task in finishing.values { task.cancel() }
    for waiter in passWaiters { waiter.resume() }
    passWaiters = []
    for continuation in continuations.values { continuation.finish() }
    continuations = [:]
  }

  // MARK: - Watching the transcripts

  private func refreshWatch() async {
    guard let events, !isStopped else { return }
    var directories: [String] = []
    for state in followed.values {
      for directory in await reader.transcriptDirectories(for: state.session)
      where !directories.contains(directory) {
        directories.append(directory)
      }
    }
    directories.sort()
    guard directories != watchedDirectories, !isStopped else { return }
    watchedDirectories = directories
    watchTask?.cancel()
    watchTask = nil
    guard !directories.isEmpty else { return }
    let stream = events.signals(for: directories)
    watchTask = Task { [weak self] in
      for await signal in stream {
        guard let self else { return }
        await self.filesChanged(signal)
      }
    }
  }

  private func filesChanged(_ signal: FileChangeSignal) {
    switch signal {
    case .changed(let paths):
      for (id, state) in followed {
        let identifiers = state.session.conversations.compactMap(\.resumeIdentifier).filter {
          !$0.isEmpty
        }
        // A session whose agent has not said its conversation yet may be the one writing.
        if !Self.namesItsConversation(state.session)
          || paths.contains(where: { path in identifiers.contains { path.contains($0) } })
        {
          requestRead(id)
        }
      }
    case .mustRescan, .rootChanged:
      for id in followed.keys { requestRead(id) }
    }
  }

  /// Gathers the reads asked for in a short while into one.
  private func requestRead(_ id: SessionID) {
    pendingReads.insert(id)
    guard readTask == nil, !isStopped else { return }
    readTask = Task { [weak self, sleep, timing] in
      try? await sleep(timing.readDelay)
      await self?.readPending()
    }
  }

  private func readPending() async {
    readTask = nil
    let ids = pendingReads
    pendingReads = []
    for id in ids where !Task.isCancelled {
      await read(id)
    }
  }

  // MARK: - Reading the transcripts

  /// Reads what the session's transcripts gained, takes the resources out of it, and asks for a
  /// summary when a turn ended. One reading of a session at a time.
  private func read(_ id: SessionID) async {
    guard var state = followed[id] else { return }
    if state.isReading {
      followed[id]?.readAgain = true
      return
    }
    followed[id]?.isReading = true
    defer { followed[id]?.isReading = false }

    // A session whose agent has not named its conversation in the store yet, as this monitor was
    // handed it: the store may know by now.
    if !Self.namesItsConversation(state.session), let repository,
      let fresh = try? await repository.session(id: id)
    {
      state.session = fresh
      followed[id]?.session = fresh
    }

    var turnEnded = false
    repeat {
      followed[id]?.readAgain = false
      guard let current = followed[id] else { return }
      let reading = await reader.read(current.session, from: current.journal.cursors)
      let date = now()
      var sightings: [ResourceSighting] = []
      for (_, event) in reading.events {
        sightings += ResourceRecognizer.sightings(in: event, now: date)
      }
      let resources = await resolution.resources(for: sightings)
      guard var latest = followed[id] else { return }
      let before = latest.journal
      latest.journal.cursors = reading.cursors
      for (providerID, event) in reading.events {
        if Self.apply(event, providerID: providerID, to: &latest.journal, now: date) {
          turnEnded = true
        }
      }
      latest.journal.record(resources)
      followed[id] = latest
      if latest.journal != before {
        scheduleSave(id)
        if latest.journal.entries != before.entries || latest.journal.resources != before.resources
          || latest.journal.hasEndedTurn != before.hasEndedTurn
        {
          publish(id)
        }
      }
    } while followed[id]?.readAgain == true

    if turnEnded { schedulePass(id) }
  }

  /// Whether the store already says which conversation the session's current agent writes.
  static func namesItsConversation(_ session: WorkSession) -> Bool {
    !(session.agent?.resumeIdentifier?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
  }

  /// What an event adds to the turns waiting for a summary. Returns whether a turn ended.
  static func apply(
    _ event: TranscriptEvent, providerID: String, to journal: inout SessionJournal, now: Date
  ) -> Bool {
    switch event {
    case .prompt(let text, _):
      journal.withOpenTurn(providerID: providerID) {
        $0.prompts.append(TurnDigest.clip(text, to: TurnDigest.promptLimit))
        if $0.prompts.count > SessionJournal.promptLimit { $0.prompts.removeFirst() }
      }
    case .toolCall(let call):
      journal.withOpenTurn(providerID: providerID) {
        if $0.actions.count < SessionJournal.actionLimit {
          $0.actions.append(
            TurnDigest.clip(TurnDigest.firstLine(call.summary), to: TurnDigest.actionLimit))
        } else {
          $0.omittedActions += 1
        }
      }
    case .agentText(let text, _):
      journal.withOpenTurn(providerID: providerID) {
        $0.agentText = TurnDigest.clip(text, to: TurnDigest.agentTextLimit)
      }
    case .creationOutput:
      break
    case .turnEnded(let at):
      let wasEnded = journal.pending.last?.endedAt != nil
      journal.endTurn(at: at ?? now)
      return !wasEnded && journal.pending.last?.endedAt != nil
    }
    return false
  }

  // MARK: - Summaries

  private func schedulePass(_ id: SessionID, after delay: Duration? = nil) {
    guard summariesEnabled, !isStopped, var state = followed[id],
      !state.journal.endedTurns.isEmpty
    else { return }
    if case .unavailable = state.journal.summary { return }
    if state.runningPass != nil {
      state.passAgain = true
      followed[id] = state
      return
    }
    state.scheduledPass?.cancel()
    var wait = delay ?? timing.quiet
    if delay == nil, let last = state.lastPassAt {
      let sinceLast = Duration.seconds(now().timeIntervalSince(last))
      wait = max(wait, timing.minimumInterval - sinceLast)
    }
    let pause = wait
    state.scheduledPass = Task { [weak self, sleep] in
      do { try await sleep(pause) } catch { return }
      await self?.startPass(id)
    }
    followed[id] = state
  }

  private func startPass(_ id: SessionID) {
    guard var state = followed[id], state.runningPass == nil, !isStopped else { return }
    state.scheduledPass = nil
    state.passAgain = false
    state.runningPass = Task { [weak self] in
      await self?.pass(id)
    }
    followed[id] = state
  }

  /// One pass: the turns that ended, condensed, handed to the session's agent. What it answers is
  /// appended; a failure leaves the turns pending and says so.
  private func pass(_ id: SessionID) async {
    await acquirePassSlot()
    defer { releasePassSlot() }
    guard let state = followed[id], !Task.isCancelled else {
      followed[id]?.runningPass = nil
      return
    }
    let turns = state.journal.endedTurns
    guard !turns.isEmpty, let providerID = state.session.agent?.providerID else {
      followed[id]?.runningPass = nil
      return
    }
    guard let summarizer = await summarizers.summarizer(for: providerID) else {
      followed[id]?.journal.summary = .unavailable(.unsupported)
      finishPass(id)
      return
    }
    publish(id)
    let since = state.journal.summarizedAt ?? .distantPast
    let digest = TurnDigest.make(
      turns: turns,
      resources: state.journal.resources.filter { $0.lastSeenAt >= since },
      recentEntries: Array(state.journal.entries.suffix(TurnDigest.recentEntryCount)))
    let request = SummaryRequest(digest: digest, turnCount: turns.count, language: language)
    let result: Result<[SummaryEntry], any Error>
    do {
      result = .success(try await summarizer.summarize(request))
    } catch {
      result = .failure(error)
    }
    guard !Task.isCancelled, var latest = followed[id] else {
      followed[id]?.runningPass = nil
      return
    }
    let date = now()
    switch result {
    case .success(let entries):
      latest.journal.append(
        entries.map { entry in
          JournalEntry(
            text: entry.text,
            at: turns[min(entry.turn, turns.count) - 1].endedAt ?? date,
            providerID: providerID)
        })
      latest.journal.summarized(Set(turns.map(\.id)), at: date)
      latest.failures = 0
      latest.lastPassAt = date
    case .failure(SummaryError.unavailable(let reason)):
      latest.journal.summary = .unavailable(reason)
    case .failure:
      latest.failures += 1
      latest.journal.summary = .failed(at: date, attempts: latest.failures)
      latest.lastPassAt = date
    }
    followed[id] = latest
    finishPass(id)
  }

  private func finishPass(_ id: SessionID) {
    guard var state = followed[id] else { return }
    state.runningPass = nil
    let again = state.passAgain
    state.passAgain = false
    followed[id] = state
    scheduleSave(id, immediately: true)
    publish(id)
    if case .failed(_, let attempts) = state.journal.summary {
      if attempts <= timing.retries.count {
        schedulePass(id, after: timing.retries[attempts - 1])
      } else if again {
        schedulePass(id)
      }
    } else if again {
      schedulePass(id)
    }
  }

  private func acquirePassSlot() async {
    if runningPasses < maximumConcurrentPasses {
      runningPasses += 1
      return
    }
    await withCheckedContinuation { passWaiters.append($0) }
  }

  private func releasePassSlot() {
    if passWaiters.isEmpty {
      runningPasses -= 1
    } else {
      passWaiters.removeFirst().resume()
    }
  }

  // MARK: - A session that stopped

  private func finish(_ id: SessionID) {
    guard followed[id] != nil, finishing[id] == nil else { return }
    finishing[id] = Task { [weak self] in
      await self?.finishNow(id)
    }
  }

  private func finishNow(_ id: SessionID) async {
    defer { finishing[id] = nil }
    // A reading under way when the session stopped is waited for: its last lines belong in the
    // last pass.
    while followed[id]?.isReading == true {
      try? await Task.sleep(for: .milliseconds(20))
    }
    await read(id)
    guard var state = followed[id] else { return }
    state.scheduledPass?.cancel()
    state.scheduledPass = nil
    // What the agent was doing when it stopped is a turn too.
    state.journal.endTurn(at: now())
    followed[id] = state
    if summariesEnabled, !isStopped, !state.journal.endedTurns.isEmpty,
      !Self.isUnavailable(state.journal.summary)
    {
      if let running = state.runningPass {
        await running.value
      }
      startPass(id)
      await followed[id]?.runningPass?.value
    }
    guard let final = followed[id] else { return }
    final.pendingSave?.cancel()
    final.scheduledPass?.cancel()
    try? await store.save(final.journal, for: id)
    // Made active again while it was being finished — restarted: it stays followed.
    if final.isActive {
      requestRead(id)
      return
    }
    followed[id] = nil
    await refreshWatch()
  }

  private static func isUnavailable(_ state: JournalSummaryState) -> Bool {
    if case .unavailable = state { return true }
    return false
  }

  // MARK: - Writing

  private func scheduleSave(_ id: SessionID, immediately: Bool = false) {
    guard var state = followed[id] else { return }
    state.pendingSave?.cancel()
    let delay = immediately ? Duration.zero : timing.saveDelay
    state.pendingSave = Task { [weak self, sleep] in
      if delay > .zero {
        do { try await sleep(delay) } catch { return }
      }
      await self?.save(id)
    }
    followed[id] = state
  }

  private func save(_ id: SessionID) async {
    guard let state = followed[id] else { return }
    followed[id]?.pendingSave = nil
    try? await store.save(state.journal, for: id)
  }
}
