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

    init(file: URL, makeDecoder: @escaping () -> any ConversationDecoding) {
      self.file = file
      self.makeDecoder = makeDecoder
      decoder = makeDecoder()
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
    for chapter in following.chapters {
      chapter.readings.forEach { $0.task?.cancel() }
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
      if following.isDirty { schedulePublish(following, key: key) }
      // Nothing wakes the reader but the disk: lines are published as they arrive. The folders
      // are looked at again for new files, often while one is still awaited, rarely after.
      let everyFileFound = following.chapters.allSatisfy {
        $0.reporter == nil || !$0.readings.isEmpty
      }
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
    publishIfNeeded(following)
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
      reading.task?.cancel()
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
    reading.task = Task { [weak self] in
      if live {
        for await chunk in tail.follow(file) {
          guard let self else { return }
          await self.received(chunk, file: file, key: key)
        }
      } else {
        let lines = await tail.read(file)
        await self?.received(.lines(lines), file: file, key: key)
      }
    }
  }

  private func received(_ chunk: TranscriptChunk, file: URL, key: UUID) {
    guard let following = followings[key],
      let reading = following.chapters.lazy.flatMap(\.readings).first(where: { $0.file == file })
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
      let chapterEntries = chapter.readings.flatMap(\.decoder.entries)
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
}

extension ConversationEntry {
  /// The call an agent is waiting on the user for, marked as such: the last call still running
  /// when the agent says it waits for a permission.
  public static func markingPendingPermission(
    _ entries: [ConversationEntry], activity: AgentActivity?
  ) -> [ConversationEntry] {
    guard activity == .awaitingUser(.approval),
      let index = entries.lastIndex(where: { $0.toolCall?.state == .running }),
      case .tool(var call) = entries[index].content
    else { return entries }
    var marked = entries
    call.state = .awaitingPermission
    marked[index].content = .tool(call)
    return marked
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
