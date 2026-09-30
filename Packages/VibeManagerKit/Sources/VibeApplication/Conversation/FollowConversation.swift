import Foundation
import VibeDomain

/// What the conversation view of one session shows at a given moment.
public struct ConversationSnapshot: Hashable, Sendable {
  public enum Availability: Hashable, Sendable {
    /// The transcripts are being read for the first time.
    case loading
    case available
    /// The agent can be followed, but has written nothing yet.
    case notYetWritten(providerName: String)
    /// The agent writes nothing the view can read: the terminal is the only view.
    case unsupported(providerName: String)
    /// A session without an agent.
    case noAgent
  }

  public var entries: [ConversationEntry]
  public var availability: Availability
  /// Grows at each publication of one follow: a reader that missed one knows it (#250).
  public var revision = 0
  /// How many entries, from the first, are the same as in the publication `revision - 1`: a
  /// reader lays out again only what follows them. 0 promises nothing.
  public var unchangedPrefix = 0

  public init(entries: [ConversationEntry] = [], availability: Availability) {
    self.entries = entries
    self.availability = availability
  }

  /// What the view shows: how the snapshot came is left out.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.availability == rhs.availability && lhs.entries == rhs.entries
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(availability)
    hasher.combine(entries)
  }

  public var isReadable: Bool {
    switch availability {
    case .loading, .available, .notYetWritten: return true
    case .unsupported, .noAgent: return false
    }
  }
}

/// Reads a session's conversations from the transcripts their CLIs write, and follows them as
/// they grow (#38).
///
/// Every conversation of the session is read — a switch of agent starts a new one — and they are
/// shown one after the other. What is read stays in memory, in the snapshots handed out, and is
/// never written anywhere (ADR 0025).
public actor FollowConversation {
  private let agents: any AgentProviderResolving
  private let tail: any TranscriptTailing
  private let hint: @Sendable (SessionID) async -> AgentActivityEvent?
  /// The session as the store has it now. Codex tells its conversation's identifier only once it
  /// has started, and a switch of agent adds a conversation: what was followed at first goes
  /// stale, and is read again.
  private let current: @Sendable (SessionID) async -> WorkSession?
  private let refreshInterval: Duration
  private let publishInterval: Duration
  /// How often a conversation nobody sees is published: still read, so that it is up to date when
  /// it comes back, but laid out by nobody meanwhile (#250).
  private let hiddenPublishInterval: Duration

  private final class Reading {
    let file: URL
    var decoder: any ConversationDecoding
    let makeDecoder: () -> any ConversationDecoding
    var hasLoaded = false
    var task: Task<Void, Never>?
    /// Followed as it grows, rather than read once to its end.
    var isFollowed = false
    /// Bumped at each start, so that what an earlier start still delivers is dropped.
    var generation = 0
    /// The transcripts of the sub-agents this one started, by the call that started each (#180):
    /// only those running, or unfolded by the user.
    var subreadings: [String: Reading] = [:]
    /// Sub-agent calls whose transcript was looked for once they were done, and not found: not
    /// looked for again.
    var notFound: Set<String> = []
    /// The sub-agent this transcript is the own of, when it is one.
    var agentID: String?
    /// Read again from its start: what was read stays shown until the new reading replaces it.
    var isRereading = false
    /// The decoder of that new reading, until it caught up with the file.
    var rereadDecoder: (any ConversationDecoding)?
    /// Where what `decoder` holds was read to: a follow resumed goes on from there (#249).
    var position: TranscriptPosition?
    /// Reading what the file already held, not yet what is written next: publications are
    /// spaced out meanwhile (#249).
    var isCatchingUp = true

    init(
      file: URL, agentID: String? = nil, makeDecoder: @escaping () -> any ConversationDecoding
    ) {
      self.file = file
      self.agentID = agentID
      self.makeDecoder = makeDecoder
      decoder = makeDecoder()
    }

    /// This reading and every one below it.
    var all: [Reading] {
      [self] + subreadings.values.flatMap(\.all)
    }
  }

  private struct Chapter {
    let providerName: String
    let reporter: (any AgentConversationReporting)?
    var readings: [Reading] = []
  }

  private final class Following {
    var session: WorkSession
    let live: Bool
    let continuation: AsyncStream<ConversationSnapshot>.Continuation
    var chapters: [Chapter] = []
    var isDirty = true
    var lastPublished: ConversationSnapshot?
    var revision = 0
    var publishTask: Task<Void, Never>?
    var tasks: [Task<Void, Never>] = []
    /// When the sub-agents of a transcript were last looked for: a sub-agent whose transcript
    /// cannot be found yet is looked for again, not at every line.
    var lastSubagentLook: [URL: ContinuousClock.Instant] = [:]

    var allReadings: [Reading] { chapters.flatMap(\.readings).flatMap(\.all) }

    init(
      session: WorkSession, live: Bool,
      continuation: AsyncStream<ConversationSnapshot>.Continuation
    ) {
      self.session = session
      self.live = live
      self.continuation = continuation
    }
  }

  private var followings: [UUID: Following] = [:]
  /// The sub-agents whose activity the user unfolded, by session: their transcripts are read,
  /// whether they run or not. Kept across the follows of a session.
  private var unfolded: [SessionID: Set<String>] = [:]
  /// Sessions whose agent does not run: a sub-agent that never said it ended there will not, and
  /// is not followed.
  private var stoppedAgents: Set<SessionID> = []
  /// When the process of each session's agent started, when known: a sub-agent started before it
  /// belonged to an earlier process, which ended without it saying so.
  private var agentStarts: [SessionID: Date] = [:]
  /// Sessions whose conversation is not on screen, and the order of the last word on it: a word
  /// older than the last one heard, arriving late, is dropped.
  private var hidden: Set<SessionID> = []
  private var shownOrders: [SessionID: Int] = [:]
  /// How often, at most, the sub-agents of one transcript are looked for.
  static let subagentLookInterval = Duration.seconds(1)

  private struct Parked {
    let agents: [SessionAgentConfiguration]
    let chapters: [Chapter]
  }

  /// The readings of sessions whose follow ended, kept with their decoders and positions (#249):
  /// followed again, they resume where they stopped instead of reading from the start. In memory
  /// only, as long as a model of the session sleeps (ADR 0025).
  private var parked: [SessionID: Parked] = [:]
  /// Sessions put aside, the oldest first.
  private var parkedOrder: [SessionID] = []
  /// Sessions whose model was let go of while their follow was ending: what it puts aside is
  /// dropped.
  private var forgotten: Set<SessionID> = []
  /// Sessions put aside at most: as many as the conversation models kept asleep.
  public static let parkedLimit = 20
  /// How often, at most, a conversation is published while its transcripts are first read: each
  /// publication composes it whole.
  static let catchingUpPublishInterval = Duration.milliseconds(250)

  public init(
    agents: any AgentProviderResolving,
    tail: any TranscriptTailing,
    hint: @escaping @Sendable (SessionID) async -> AgentActivityEvent? = { _ in nil },
    current: @escaping @Sendable (SessionID) async -> WorkSession? = { _ in nil },
    refreshInterval: Duration = .seconds(2),
    publishInterval: Duration = .milliseconds(50),
    hiddenPublishInterval: Duration = .seconds(1)
  ) {
    self.agents = agents
    self.tail = tail
    self.hint = hint
    self.current = current
    self.refreshInterval = refreshInterval
    self.publishInterval = publishInterval
    self.hiddenPublishInterval = hiddenPublishInterval
  }

  /// The session's conversation, then every change to it while the stream is kept — or only
  /// once, when `live` is false: a closed or archived session writes nothing more.
  public func follow(_ session: WorkSession, live: Bool = true) -> AsyncStream<ConversationSnapshot>
  {
    let (stream, continuation) = AsyncStream<ConversationSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let key = UUID()
    let following = Following(session: session, live: live, continuation: continuation)
    followings[key] = following
    forgotten.remove(session.id)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.stop(key) }
    }
    following.tasks.append(Task { await self.run(key) })
    return stream
  }

  private func stop(_ key: UUID) {
    guard let following = followings.removeValue(forKey: key) else { return }
    following.tasks.forEach { $0.cancel() }
    following.publishTask?.cancel()
    following.allReadings.forEach { $0.task?.cancel() }
    let id = following.session.id
    if following.live, !forgotten.contains(id) { park(following) }
    // Forgotten for the follows that were ending when its model was let go of: once none is left,
    // there is nothing more to forget.
    if !followings.values.contains(where: { $0.session.id == id }) { forgotten.remove(id) }
  }

  /// The sessions put aside, the oldest first: for tests.
  var parkedSessionIDs: [SessionID] { parkedOrder }

  /// How many follows are under way: for tests.
  var followCount: Int { followings.count }

  /// Forgets what was put aside for the session: its model was let go of.
  public func forget(_ session: SessionID) {
    parked[session] = nil
    parkedOrder.removeAll { $0 == session }
    // A follow still ending would put its readings aside after this.
    if followings.values.contains(where: { $0.session.id == session }) {
      forgotten.insert(session)
    }
  }

  private func park(_ following: Following) {
    let id = following.session.id
    for reading in following.allReadings where reading.isRereading {
      // Its new reading was under way: done again, from the start, when resumed.
      reading.rereadDecoder = nil
      reading.position = nil
    }
    parked[id] = Parked(agents: following.session.conversationAgents, chapters: following.chapters)
    parkedOrder.removeAll { $0 == id }
    parkedOrder.append(id)
    while parkedOrder.count > Self.parkedLimit {
      parked[parkedOrder.removeFirst()] = nil
    }
  }

  /// Takes back what the session's last follow put aside: its conversation is there at once, and
  /// its readings go on where they stopped — only what was written meanwhile is read.
  private func resume(_ following: Following, key: UUID) {
    let id = following.session.id
    guard let kept = parked.removeValue(forKey: id) else { return }
    parkedOrder.removeAll { $0 == id }
    for reading in reuse(kept.chapters, of: kept.agents, in: following).flatMap(\.all) {
      // A sub-agent read once to its end, done, stays as it is.
      guard reading.isFollowed || !reading.hasLoaded || reading.isRereading else { continue }
      if reading.isFollowed, reading.hasLoaded, reading.position == nil {
        // Where it stopped is not known: read again, what it showed staying until then.
        reading.isRereading = true
      }
      start(reading, key: key, live: reading.isFollowed, from: reading.position)
    }
    following.isDirty = true
  }

  /// The sub-agents whose activity the user unfolded in the session (#180): their transcripts are
  /// read now, and kept read while they stay unfolded.
  public func setUnfoldedSubagents(_ callIDs: Set<String>, for session: SessionID) {
    guard unfolded[session, default: []] != callIDs else { return }
    unfolded[session] = callIDs
    for (key, following) in followings where following.session.id == session {
      following.lastSubagentLook = [:]
      refreshSubagents(following, key: key)
      following.isDirty = true
      if following.live { schedulePublish(following, key: key) }
    }
  }

  /// Whether the session's conversation is on screen (#250). Hidden, it is still read, but
  /// published only every `hiddenPublishInterval`; shown again, what waits is published at once.
  ///
  /// - Parameter order: grows with each word from the view, so that one arriving after a later
  ///   one changes nothing.
  public func setShown(_ shown: Bool, for session: SessionID, order: Int) {
    if let last = shownOrders[session], order <= last { return }
    shownOrders[session] = order
    let changed = shown ? hidden.remove(session) != nil : hidden.insert(session).inserted
    guard changed, shown else { return }
    for (key, following) in followings
    where following.session.id == session && following.live && following.publishTask != nil {
      following.publishTask?.cancel()
      publishNow(key)
    }
  }

  func isHidden(_ session: SessionID) -> Bool { hidden.contains(session) }

  /// Whether what was read waits to be published, every file read, for the tests.
  func hasPendingPublication(for session: SessionID) -> Bool {
    followings.values.contains {
      $0.session.id == session && $0.publishTask != nil && !$0.allReadings.isEmpty
        && isLoaded($0)
    }
  }

  /// Whether the session's agent runs, and since when. Its sub-agents that never said they ended
  /// are not followed while it does not, nor those started before it — by a process resumed since
  /// (#180): they will not end.
  public func setAgentRunning(
    _ isRunning: Bool, since startedAt: Date? = nil, for session: SessionID
  ) {
    // Running with no date says nothing of the date: one already known for this run is kept.
    let start =
      isRunning ? startedAt ?? (stoppedAgents.contains(session) ? nil : agentStarts[session]) : nil
    guard stoppedAgents.contains(session) == isRunning || agentStarts[session] != start else {
      return
    }
    if isRunning { stoppedAgents.remove(session) } else { stoppedAgents.insert(session) }
    agentStarts[session] = start
    for (key, following) in followings where following.session.id == session {
      refreshSubagents(following, key: key)
      following.isDirty = true
      if following.live { schedulePublish(following, key: key) }
    }
  }

  /// A sub-agent at work, as far as reading it goes: not done, under no sub-agent that ended —
  /// its own calls end with it, results or not — in a session followed live whose agent runs, and
  /// started by that agent's process rather than an earlier one.
  private func isRunning(_ call: ToolCall, in following: Following, underEnded: Bool) -> Bool {
    let id = following.session.id
    guard !underEnded, !call.state.isFinished, following.live, !stoppedAgents.contains(id)
    else { return false }
    guard let start = agentStarts[id], let started = call.subagent?.startedAt else { return true }
    return !SubagentRun.predates(started, process: start)
  }

  private func run(_ key: UUID) async {
    guard let following = followings[key] else { return }
    await prepareChapters(following)
    guard following.chapters.contains(where: { $0.reporter != nil }) else {
      let name = following.chapters.last?.providerName
      following.continuation.yield(
        ConversationSnapshot(availability: name.map { .unsupported(providerName: $0) } ?? .noAgent))
      following.continuation.finish()
      return
    }
    if following.live { resume(following, key: key) }
    while !Task.isCancelled, followings[key] != nil {
      await refreshFiles(following, key: key)
      guard following.live else {
        // Read once: published when every file has been read, then done.
        while !isLoaded(following), !Task.isCancelled {
          try? await Task.sleep(for: publishInterval)
        }
        publishIfNeeded(following)
        following.continuation.finish()
        return
      }
      // A sub-agent's transcript may appear with nothing new in the conversation's own.
      refreshSubagents(following, key: key)
      if following.isDirty { schedulePublish(following, key: key) }
      // Nothing wakes the reader but the disk: lines are published as they arrive. The folders
      // are looked at again for new files, often while one is still awaited, rarely after.
      let everyFileFound =
        following.chapters.allSatisfy { $0.reporter == nil || !$0.readings.isEmpty }
        && !hasUnreadRunningSubagent(following)
      try? await Task.sleep(for: everyFileFound ? refreshInterval * 5 : refreshInterval)
    }
  }

  /// One publication per pause, whatever the number of chunks that arrived in it: a longer pause
  /// while transcripts are first read, and longer still for a conversation nobody sees.
  private func schedulePublish(_ following: Following, key: UUID) {
    guard following.publishTask == nil else { return }
    var interval = publishInterval
    if isCatchingUp(following) { interval = max(interval, Self.catchingUpPublishInterval) }
    if hidden.contains(following.session.id) { interval = max(interval, hiddenPublishInterval) }
    following.publishTask = Task { [weak self] in
      try? await Task.sleep(for: interval)
      // Cut short by the conversation coming on screen, which published already.
      guard !Task.isCancelled else { return }
      await self?.publishNow(key)
    }
  }

  private func isCatchingUp(_ following: Following) -> Bool {
    following.allReadings.contains(where: \.isCatchingUp)
  }

  private func publishNow(_ key: UUID) {
    guard let following = followings[key] else { return }
    following.publishTask = nil
    refreshSubagents(following, key: key)
    publishIfNeeded(following)
  }

  // MARK: - Sub-agents

  /// Starts reading the transcripts of the sub-agents that run or that the user unfolded, and
  /// stops following those that ended folded (#180). A conversation of fifty sub-agents that are
  /// done opens none of their files.
  private func refreshSubagents(_ following: Following, key: UUID) {
    let wanted = unfolded[following.session.id] ?? []
    for chapter in following.chapters {
      guard let reporter = chapter.reporter else { continue }
      for root in chapter.readings {
        refreshSubagents(
          of: root, root: root.file, depth: 1, underEnded: false, reporter: reporter,
          wanted: wanted, following: following, key: key)
      }
    }
  }

  private func refreshSubagents(
    of reading: Reading, root: URL, depth: Int, underEnded: Bool,
    reporter: any AgentConversationReporting, wanted: Set<String>, following: Following, key: UUID
  ) {
    guard depth <= SubagentRun.maximumShownDepth else { return }
    var needed: [ToolCall] = []
    for call in reading.decoder.entries.compactMap(\.subagentCall) {
      let running = isRunning(call, in: following, underEnded: underEnded)
      let isWanted = running || wanted.contains(call.callID)
      guard let sub = reading.subreadings[call.callID] else {
        // One that is done and was not found once will not be.
        if isWanted, running || !reading.notFound.contains(call.callID) { needed.append(call) }
        continue
      }
      if sub.isFollowed, !running {
        // Ended: read once more to its end, then left alone.
        restart(sub, key: key, follows: false)
      } else if !sub.isFollowed, running {
        // Given another task.
        restart(sub, key: key, follows: true)
      }
      refreshSubagents(
        of: sub, root: root, depth: depth + 1,
        underEnded: underEnded || call.state.isFinished, reporter: reporter, wanted: wanted,
        following: following, key: key)
    }
    guard !needed.isEmpty else { return }
    let now = ContinuousClock.now
    if let last = following.lastSubagentLook[reading.file],
      now - last < Self.subagentLookInterval
    {
      return
    }
    following.lastSubagentLook[reading.file] = now
    let transcripts = reporter.subagentTranscripts(
      beside: root, agentIDs: Set(needed.compactMap { $0.subagent?.agentID }))
    let links = SubagentLinker.link(
      needed.map {
        SubagentLinker.Call(
          callID: $0.callID, agentID: $0.subagent?.agentID, prompt: $0.parameter(.prompt),
          date: $0.subagent?.startedAt)
      },
      among: transcripts, taken: Set(following.allReadings.map(\.file)),
      firstPrompt: reporter.firstPrompt(ofSubagent:))
    for call in needed {
      guard let transcript = links[call.callID] else {
        if !isRunning(call, in: following, underEnded: underEnded) {
          reading.notFound.insert(call.callID)
          following.isDirty = true
        }
        continue
      }
      let file = transcript.file
      let sub = Reading(file: file, agentID: transcript.agentID) {
        reporter.subagentDecoder(for: file, root: root)
      }
      reading.subreadings[call.callID] = sub
      start(sub, key: key, live: isRunning(call, in: following, underEnded: underEnded))
      following.isDirty = true
    }
  }

  /// A sub-agent runs, within the depth shown, whose transcript was not found yet: it is looked
  /// for often.
  private func hasUnreadRunningSubagent(_ following: Following) -> Bool {
    func unread(_ reading: Reading, depth: Int, underEnded: Bool) -> Bool {
      guard depth <= SubagentRun.maximumShownDepth else { return false }
      return reading.decoder.entries.contains { entry in
        guard let call = entry.subagentCall else { return false }
        if let sub = reading.subreadings[call.callID] {
          return unread(
            sub, depth: depth + 1, underEnded: underEnded || call.state.isFinished)
        }
        return isRunning(call, in: following, underEnded: underEnded)
      }
    }
    return following.chapters.flatMap(\.readings).contains {
      unread($0, depth: 1, underEnded: false)
    }
  }

  /// Read again from its start — once to its end, or followed — what it showed staying until the
  /// new reading replaces it: an activity does not blink when its sub-agent ends.
  private func restart(_ reading: Reading, key: UUID, follows: Bool) {
    reading.task?.cancel()
    reading.isRereading = true
    reading.rereadDecoder = nil
    start(reading, key: key, live: follows)
  }

  /// Follows the session as it is now: the chapters it already had keep what they read, a
  /// conversation that gained its identifier starts reading, a new one is added.
  private func adopt(_ latest: WorkSession, in following: Following) async {
    let previous = following.chapters
    let previousAgents = following.session.conversationAgents
    following.session = latest
    await prepareChapters(following)
    let reused = Set(reuse(previous, of: previousAgents, in: following).map(ObjectIdentifier.init))
    for reading in previous.flatMap(\.readings) where !reused.contains(ObjectIdentifier(reading)) {
      reading.all.forEach { $0.task?.cancel() }
    }
    following.isDirty = true
  }

  /// Gives the chapters of `following` the readings of `previous` — chapters of the conversations
  /// `previousAgents` — whose conversation is still there. The readings given.
  private func reuse(
    _ previous: [Chapter], of previousAgents: [SessionAgentConfiguration], in following: Following
  ) -> [Reading] {
    var reused: [Reading] = []
    for (index, agent) in following.session.conversationAgents.enumerated() {
      guard let kept = previousAgents.firstIndex(of: agent), kept < previous.count,
        index < following.chapters.count
      else { continue }
      following.chapters[index].readings = previous[kept].readings
      reused += previous[kept].readings
    }
    return reused
  }

  private func prepareChapters(_ following: Following) async {
    var chapters: [Chapter] = []
    for conversation in following.session.conversationAgents {
      let provider = await agents.provider(id: AgentProviderID(conversation.providerID))
      chapters.append(
        Chapter(
          providerName: provider?.descriptor.displayName ?? conversation.providerID,
          reporter: provider as? any AgentConversationReporting))
    }
    following.chapters = chapters
  }

  /// Looks for files the CLIs started since the last look: a first exchange, a `/clear`, a resume
  /// the next day.
  private func refreshFiles(_ following: Following, key: UUID) async {
    if let latest = await current(following.session.id),
      latest.conversationAgents != following.session.conversationAgents
    {
      await adopt(latest, in: following)
    }
    let conversations = following.session.conversationAgents
    let lastHint = await hint(following.session.id)
    for index in following.chapters.indices {
      guard let reporter = following.chapters[index].reporter, index < conversations.count
      else { continue }
      let isLast = index == following.chapters.count - 1
      let files = reporter.conversationFiles(
        for: conversations[index], in: following.session, hint: isLast ? lastHint : nil)
      let known = Set(following.chapters[index].readings.map(\.file))
      for file in files where !known.contains(file) {
        let reading = Reading(file: file) { reporter.conversationDecoder(for: file) }
        following.chapters[index].readings.append(reading)
        start(reading, key: key, live: following.live)
      }
    }
  }

  /// - Parameter position: where a reading put aside stopped, to go on from there (#249).
  private func start(
    _ reading: Reading, key: UUID, live: Bool, from position: TranscriptPosition? = nil
  ) {
    let tail = tail
    let file = reading.file
    reading.generation += 1
    reading.isFollowed = live
    reading.isCatchingUp = position == nil
    let generation = reading.generation
    reading.task = Task { [weak self] in
      if live {
        for await chunk in tail.follow(file, from: position) {
          guard let self else { return }
          await self.received(chunk, file: file, generation: generation, key: key)
        }
      } else {
        // Decoded a chunk at a time too: a long transcript of a sub-agent that ended is never
        // held whole on its way to its decoder.
        for await chunk in tail.readChunks(file) {
          guard let self else { return }
          await self.received(chunk, file: file, generation: generation, key: key)
        }
      }
    }
  }

  private func received(_ chunk: TranscriptChunk, file: URL, generation: Int, key: UUID) {
    guard let following = followings[key],
      let reading = following.allReadings.first(where: { $0.file == file }),
      // What a reading started before it was restarted says is forgotten with it.
      reading.generation == generation
    else { return }
    let wasCatchingUp = isCatchingUp(following)
    switch chunk {
    case .reset:
      reading.position = nil
      if reading.hasLoaded {
        // Read again from its start, what it showed staying until the new reading caught up.
        reading.isRereading = true
        reading.rereadDecoder = nil
      } else {
        reading.decoder = reading.makeDecoder()
      }
    case .records(let records, let through, let isCaughtUp):
      if let through { reading.position = through }
      reading.isCatchingUp = !isCaughtUp
      Signposts.interval("conversation.decode") {
        if reading.isRereading {
          // The whole file again, read apart — a chunk at a time — before it replaces what was
          // shown.
          let decoder = reading.rereadDecoder ?? reading.makeDecoder()
          for record in records { decoder.consume(record) }
          if isCaughtUp {
            reading.decoder = decoder
            reading.rereadDecoder = nil
            reading.isRereading = false
          } else {
            reading.rereadDecoder = decoder
          }
        } else {
          for record in records { reading.decoder.consume(record) }
        }
      }
      reading.hasLoaded = true
    }
    following.isDirty = true
    guard following.live else { return }
    if wasCatchingUp, !isCatchingUp(following), let pending = following.publishTask {
      // Every transcript caught up: what waited for the longer pause is shown now.
      pending.cancel()
      following.publishTask = nil
    }
    schedulePublish(following, key: key)
  }

  private func isLoaded(_ following: Following) -> Bool {
    following.chapters.allSatisfy { $0.readings.allSatisfy(\.hasLoaded) }
  }

  private func publishIfNeeded(_ following: Following) {
    guard following.isDirty else { return }
    following.isDirty = false
    var snapshot = Signposts.interval("conversation.compose") { compose(following) }
    // Compared from the start, and only as far as it is the same: what follows is what the
    // reader lays out again (#250).
    let previous = following.lastPublished
    let unchanged = previous.map { Self.commonPrefix($0.entries, snapshot.entries) } ?? 0
    if let previous, previous.availability == snapshot.availability,
      unchanged == previous.entries.count, unchanged == snapshot.entries.count
    {
      return
    }
    following.revision += 1
    snapshot.revision = following.revision
    snapshot.unchangedPrefix = unchanged
    following.lastPublished = snapshot
    following.continuation.yield(snapshot)
  }

  /// How many entries, from the first, two lists share.
  static func commonPrefix(_ old: [ConversationEntry], _ new: [ConversationEntry]) -> Int {
    var index = 0
    let end = min(old.count, new.count)
    while index < end, old[index] == new[index] { index += 1 }
    return index
  }

  private func compose(_ following: Following) -> ConversationSnapshot {
    var entries: [ConversationEntry] = []
    let showsChapters = following.chapters.count > 1
    for (index, chapter) in following.chapters.enumerated() {
      guard chapter.reporter != nil else { continue }
      let chapterEntries = chapter.readings.flatMap {
        shownEntries(
          of: $0, depth: 1, underEnded: false, wanted: unfolded[following.session.id] ?? [],
          following: following)
      }
      if showsChapters, index > 0, !chapterEntries.isEmpty {
        entries.append(
          ConversationEntry(
            id: "chapter:\(index)", date: chapterEntries.first?.date,
            content: .notice(
              .chapter(providerName: chapter.providerName, date: chapterEntries.first?.date))))
      }
      entries.append(contentsOf: chapterEntries)
    }
    let availability: ConversationSnapshot.Availability
    if !isLoaded(following) {
      availability = .loading
    } else if entries.isEmpty {
      availability = .notYetWritten(
        providerName: following.chapters.last(where: { $0.reporter != nil })?.providerName ?? "")
    } else {
      availability = .available
    }
    return ConversationSnapshot(entries: entries, availability: availability)
  }

  /// A transcript's entries, each sub-agent carrying its depth and, when its transcript was read,
  /// its activity (#180). Under a sub-agent that ended, a call still waiting for its result will
  /// not have it: it is shown stopped.
  private func shownEntries(
    of reading: Reading, depth: Int, underEnded: Bool, wanted: Set<String>, following: Following
  ) -> [ConversationEntry] {
    var entries = reading.decoder.entries
    for index in entries.indices {
      guard case .tool(var call) = entries[index].content else { continue }
      if underEnded, !call.state.isFinished {
        call.state = .interrupted
        entries[index].content = .tool(call)
      }
      guard call.kind == .subagent else { continue }
      var run = call.subagent ?? SubagentRun()
      run.depth = depth
      if let sub = reading.subreadings[call.callID] {
        run.transcript = sub.file
        // A sub-agent in front says who it is only when it returns: its transcript says it first.
        if run.agentID == nil { run.agentID = sub.agentID }
        if sub.hasLoaded {
          let inner = shownEntries(
            of: sub, depth: depth + 1, underEnded: underEnded || call.state.isFinished,
            wanted: wanted, following: following)
          run.activity = .read(inner)
          // What it said last is its answer, when the main transcript does not carry it: Codex
          // writes it in the sub-agent's rollout only.
          if run.result == nil, call.state == .succeeded,
            let last = inner.last(where: {
              if case .agentText = $0.content { return true }
              return false
            }), case .agentText(let text) = last.content
          {
            run.result = text
          }
        } else {
          run.activity = .loading
        }
      } else if reading.notFound.contains(call.callID) {
        run.activity = .notFound
      } else if depth <= SubagentRun.maximumShownDepth,
        isRunning(call, in: following, underEnded: underEnded) || wanted.contains(call.callID)
      {
        run.activity = .loading
      }
      call.subagent = run
      entries[index].content = .tool(call)
    }
    return entries
  }
}

extension ConversationEntry {
  /// The call an agent is waiting on the user for, marked as such: the last call still running
  /// when the agent says it waits for a permission.
  ///
  /// A request a sub-agent made (`agentID`, from the hook that reported it) marks the last call
  /// running in that sub-agent's activity, or the sub-agent itself while its activity is not read
  /// (#180). Otherwise a sub-agent, which runs on its own, is never the call waited on.
  public static func markingPendingPermission(
    _ entries: [ConversationEntry], activity: AgentActivity?, agentID: String? = nil
  ) -> [ConversationEntry] {
    guard let mark = pendingPermissionMark(entries, activity: activity, agentID: agentID) else {
      return entries
    }
    var marked = entries
    marked[mark.index] = mark.entry
    return marked
  }

  /// The one entry `markingPendingPermission` changes, and where: a view that laid the others out
  /// already lays out again only from there (#250).
  public static func pendingPermissionMark(
    _ entries: [ConversationEntry], activity: AgentActivity?, agentID: String? = nil
  ) -> (index: Int, entry: ConversationEntry)? {
    guard activity == .awaitingUser(.approval) else { return nil }
    if let agentID, let marked = marking(agentID: agentID, in: entries) { return marked }
    guard
      let index = entries.lastIndex(where: {
        $0.toolCall?.state == .running && $0.toolCall?.kind != .subagent
      }),
      case .tool(var call) = entries[index].content
    else { return nil }
    var marked = entries[index]
    call.state = .awaitingPermission
    marked.content = .tool(call)
    return (index, marked)
  }

  private static func marking(agentID: String, in entries: [ConversationEntry])
    -> (index: Int, entry: ConversationEntry)?
  {
    for index in entries.indices {
      guard case .tool(var call) = entries[index].content, call.kind == .subagent,
        var run = call.subagent
      else { continue }
      var marked = entries[index]
      if run.agentID == agentID {
        if let inner = run.activityEntries,
          inner.contains(where: { $0.toolCall?.state == .running })
        {
          run.activity = .read(markingPendingPermission(inner, activity: .awaitingUser(.approval)))
          call.subagent = run
        }
        call.state = .awaitingPermission
        marked.content = .tool(call)
        return (index, marked)
      }
      if let inner = run.activityEntries, let found = marking(agentID: agentID, in: inner) {
        var innerMarked = inner
        innerMarked[found.index] = found.entry
        run.activity = .read(innerMarked)
        call.subagent = run
        call.state = .awaitingPermission
        marked.content = .tool(call)
        return (index, marked)
      }
    }
    return nil
  }
}

extension WorkSession {
  /// The conversations to show: every one the session had, and the current agent's even before
  /// it has an identifier — Codex tells its own only once it has started — so that the view
  /// waits for it rather than saying there is nothing to read.
  public var conversationAgents: [SessionAgentConfiguration] {
    var agents = conversations
    if let agent,
      !agents.contains(where: {
        $0.providerID == agent.providerID && $0.resumeIdentifier == agent.resumeIdentifier
      })
    {
      agents.append(agent)
    }
    return agents
  }
}
