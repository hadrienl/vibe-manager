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

  public init(entries: [ConversationEntry] = [], availability: Availability) {
    self.entries = entries
    self.availability = availability
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

    init(file: URL, makeDecoder: @escaping () -> any ConversationDecoding) {
      self.file = file
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
  /// How often, at most, the sub-agents of one transcript are looked for.
  static let subagentLookInterval = Duration.seconds(1)

  public init(
    agents: any AgentProviderResolving,
    tail: any TranscriptTailing,
    hint: @escaping @Sendable (SessionID) async -> AgentActivityEvent? = { _ in nil },
    current: @escaping @Sendable (SessionID) async -> WorkSession? = { _ in nil },
    refreshInterval: Duration = .seconds(2),
    publishInterval: Duration = .milliseconds(50)
  ) {
    self.agents = agents
    self.tail = tail
    self.hint = hint
    self.current = current
    self.refreshInterval = refreshInterval
    self.publishInterval = publishInterval
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

  /// One publication per pause, whatever the number of chunks that arrived in it.
  private func schedulePublish(_ following: Following, key: UUID) {
    guard following.publishTask == nil else { return }
    let interval = publishInterval
    following.publishTask = Task { [weak self] in
      try? await Task.sleep(for: interval)
      await self?.publishNow(key)
    }
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
          of: root, root: root.file, depth: 1, reporter: reporter, wanted: wanted,
          following: following, key: key)
      }
    }
  }

  private func refreshSubagents(
    of reading: Reading, root: URL, depth: Int, reporter: any AgentConversationReporting,
    wanted: Set<String>, following: Following, key: UUID
  ) {
    guard depth <= SubagentRun.maximumShownDepth else { return }
    var needed: [ToolCall] = []
    for call in reading.decoder.entries.compactMap(\.subagentCall) {
      let running = !call.state.isFinished && following.live
      let isWanted = running || wanted.contains(call.callID)
      guard let sub = reading.subreadings[call.callID] else {
        if isWanted { needed.append(call) }
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
        of: sub, root: root, depth: depth + 1, reporter: reporter, wanted: wanted,
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
    guard !transcripts.isEmpty else { return }
    let links = SubagentLinker.link(
      needed.map {
        SubagentLinker.Call(
          callID: $0.callID, agentID: $0.subagent?.agentID, prompt: $0.parameter(.prompt),
          date: $0.subagent?.startedAt)
      },
      among: transcripts, taken: Set(following.allReadings.map(\.file)),
      firstPrompt: reporter.firstPrompt(ofSubagent:))
    for call in needed {
      guard let transcript = links[call.callID] else { continue }
      let file = transcript.file
      let sub = Reading(file: file) { reporter.subagentDecoder(for: file, root: root) }
      reading.subreadings[call.callID] = sub
      start(sub, key: key, live: !call.state.isFinished && following.live)
      following.isDirty = true
    }
  }

  /// A sub-agent runs whose transcript was not found yet: it is looked for often.
  private func hasUnreadRunningSubagent(_ following: Following) -> Bool {
    following.allReadings.contains { reading in
      reading.decoder.entries.contains { entry in
        guard let call = entry.subagentCall else { return false }
        return !call.state.isFinished && reading.subreadings[call.callID] == nil
      }
    }
  }

  private func restart(_ reading: Reading, key: UUID, follows: Bool) {
    reading.task?.cancel()
    reading.decoder = reading.makeDecoder()
    reading.hasLoaded = false
    start(reading, key: key, live: follows)
  }

  /// Follows the session as it is now: the chapters it already had keep what they read, a
  /// conversation that gained its identifier starts reading, a new one is added.
  private func adopt(_ latest: WorkSession, in following: Following) async {
    let previous = following.chapters
    let previousAgents = following.session.conversationAgents
    following.session = latest
    await prepareChapters(following)
    for (index, agent) in latest.conversationAgents.enumerated() {
      guard let kept = previousAgents.firstIndex(of: agent), kept < previous.count,
        index < following.chapters.count
      else { continue }
      following.chapters[index].readings = previous[kept].readings
    }
    let reused = Set(following.chapters.flatMap(\.readings).map(ObjectIdentifier.init))
    for reading in previous.flatMap(\.readings) where !reused.contains(ObjectIdentifier(reading)) {
      reading.all.forEach { $0.task?.cancel() }
    }
    following.isDirty = true
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

  private func start(_ reading: Reading, key: UUID, live: Bool) {
    let tail = tail
    let file = reading.file
    reading.generation += 1
    reading.isFollowed = live
    let generation = reading.generation
    reading.task = Task { [weak self] in
      if live {
        for await chunk in tail.follow(file) {
          guard let self else { return }
          await self.received(chunk, file: file, generation: generation, key: key)
        }
      } else {
        let lines = await tail.read(file)
        await self?.received(.lines(lines), file: file, generation: generation, key: key)
      }
    }
  }

  private func received(_ chunk: TranscriptChunk, file: URL, generation: Int, key: UUID) {
    guard let following = followings[key],
      let reading = following.allReadings.first(where: { $0.file == file }),
      // What a reading started before it was restarted says is forgotten with it.
      reading.generation == generation
    else { return }
    switch chunk {
    case .reset:
      reading.decoder = reading.makeDecoder()
    case .lines(let lines):
      for line in lines { reading.decoder.consume(line) }
      reading.hasLoaded = true
    }
    following.isDirty = true
    if following.live { schedulePublish(following, key: key) }
  }

  private func isLoaded(_ following: Following) -> Bool {
    following.chapters.allSatisfy { $0.readings.allSatisfy(\.hasLoaded) }
  }

  private func publishIfNeeded(_ following: Following) {
    guard following.isDirty else { return }
    following.isDirty = false
    let snapshot = compose(following)
    guard snapshot != following.lastPublished else { return }
    following.lastPublished = snapshot
    following.continuation.yield(snapshot)
  }

  private func compose(_ following: Following) -> ConversationSnapshot {
    var entries: [ConversationEntry] = []
    let showsChapters = following.chapters.count > 1
    for (index, chapter) in following.chapters.enumerated() {
      guard chapter.reporter != nil else { continue }
      let chapterEntries = chapter.readings.flatMap {
        shownEntries(of: $0, depth: 1, wanted: unfolded[following.session.id] ?? [],
          live: following.live)
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
  /// its activity (#180).
  private func shownEntries(of reading: Reading, depth: Int, wanted: Set<String>, live: Bool)
    -> [ConversationEntry]
  {
    var entries = reading.decoder.entries
    for index in entries.indices {
      guard case .tool(var call) = entries[index].content, call.kind == .subagent else {
        continue
      }
      var run = call.subagent ?? SubagentRun()
      run.depth = depth
      if let sub = reading.subreadings[call.callID] {
        run.transcript = sub.file
        if sub.hasLoaded {
          let inner = shownEntries(of: sub, depth: depth + 1, wanted: wanted, live: live)
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
      } else if depth <= SubagentRun.maximumShownDepth,
        (live && !call.state.isFinished) || wanted.contains(call.callID)
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
    guard activity == .awaitingUser(.approval) else { return entries }
    if let agentID, let marked = marking(agentID: agentID, in: entries) { return marked }
    guard
      let index = entries.lastIndex(where: {
        $0.toolCall?.state == .running && $0.toolCall?.kind != .subagent
      }),
      case .tool(var call) = entries[index].content
    else { return entries }
    var marked = entries
    call.state = .awaitingPermission
    marked[index].content = .tool(call)
    return marked
  }

  private static func marking(agentID: String, in entries: [ConversationEntry])
    -> [ConversationEntry]?
  {
    for index in entries.indices {
      guard case .tool(var call) = entries[index].content, call.kind == .subagent,
        var run = call.subagent
      else { continue }
      var marked = entries
      if run.agentID == agentID {
        if let inner = run.activityEntries,
          inner.contains(where: { $0.toolCall?.state == .running })
        {
          run.activity = .read(markingPendingPermission(inner, activity: .awaitingUser(.approval)))
          call.subagent = run
        }
        call.state = .awaitingPermission
        marked[index].content = .tool(call)
        return marked
      }
      if let inner = run.activityEntries, let found = marking(agentID: agentID, in: inner) {
        run.activity = .read(found)
        call.subagent = run
        call.state = .awaitingPermission
        marked[index].content = .tool(call)
        return marked
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
