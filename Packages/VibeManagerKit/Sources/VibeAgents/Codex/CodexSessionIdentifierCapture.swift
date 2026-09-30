import Foundation
import VibeApplication
import VibeDomain

/// Feeds terminal output to the extractor across the chunk boundaries a pseudo terminal
/// creates.
///
/// A read cuts wherever the kernel buffer ended, so an identifier — or the word that gives it
/// its meaning — regularly straddles two chunks. The accumulator keeps the unterminated tail
/// of the stream, bounded, and hands complete lines to the extractor.
public actor CodexTerminalIdentifierAccumulator {
  /// A rollout identifier lives on one line of a terminal; a longer tail is a progress bar or
  /// a full screen repaint, never the line being waited for.
  static let maximumTailByteCount = 8 * 1024

  private let extractor: CodexResumeIdentifierExtractor
  private let willConsume: (@Sendable () async -> Void)?
  private var tail = ""
  private var found: String?

  /// - Parameter willConsume: awaited before each read is accumulated. It exists so a test can
  ///   hold a read in flight and check what the caller does with the ones arriving meanwhile.
  public init(
    extractor: CodexResumeIdentifierExtractor = CodexResumeIdentifierExtractor(),
    willConsume: (@Sendable () async -> Void)? = nil
  ) {
    self.extractor = extractor
    self.willConsume = willConsume
  }

  public var identifier: String? {
    found
  }

  /// - Returns: the identifier the first time one is recognised, `nil` afterwards.
  @discardableResult
  public func consume(_ text: String) async -> String? {
    await willConsume?()
    guard found == nil else { return nil }

    let combined = tail + text
    let hasCompleteTail = combined.last.map(\.isNewline) ?? false
    var lines = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map(String.init)
    tail = hasCompleteTail ? "" : (lines.popLast() ?? "")
    if tail.utf8.count > Self.maximumTailByteCount {
      // Truncate on a UTF-8 boundary: `suffix` counts Characters, and a line of CJK or
      // box-drawing output would leave a tail several times over the intended bound.
      tail = String(decoding: tail.utf8.suffix(Self.maximumTailByteCount), as: UTF8.self)
    }

    for line in lines {
      guard let identifier = extractor.resumeIdentifier(in: line) else { continue }
      found = identifier
      return identifier
    }
    // A line still being written can already carry the identifier, so the tail is examined
    // too — without consuming it, since more of it may still arrive.
    if let identifier = extractor.resumeIdentifier(in: tail) {
      found = identifier
      return identifier
    }
    return nil
  }
}

/// Captures the identifier of a running Codex session and stores it on its work session.
///
/// Codex creates its session when it starts but names it nowhere until the first message, which
/// may come hours later (#144). Three sources can name it:
///
/// - the agent's own `SessionStart` hook (`named(_:)`), written by this very process into its
///   session's log: the only one that cannot belong to another launch, and so the one that wins
///   over the others, even after them;
/// - the rollout file Codex writes, found by `CodexSessionDiscovering` among those of the same
///   folder: reliable, as long as no other launch may have written it;
/// - the terminal output, which is immediate but only as stable as the interface.
///
/// Between the last two, the first to produce an identifier wins and nothing but the hook
/// overwrites it for the rest of the launch. A later launch of the same work session does replace
/// it: that is a new conversation.
public actor CodexSessionIdentifierCapture {
  /// How long the rollout is looked for when the hooks can name the session: the net under them,
  /// for as long as it always was.
  public static let defaultTimeout: Duration = .seconds(30)
  /// How long the rollout is looked for when nothing else will name the session — a launch without
  /// hooks. The process ending stops the watch well before, as a rule: this is only the safety
  /// net, set for a working day.
  public static let defaultWatchLimit: Duration = .seconds(12 * 3600)
  public static let defaultPersistenceWindow: Duration = .seconds(30)
  /// How much terminal output may wait to be accumulated before the oldest read is dropped.
  static let maximumQueuedByteCount = 256 * 1024

  private enum Source {
    case rollout
    case terminal
    case hook
  }

  private enum Persistence {
    case kept
    case retry
    case rejected
  }

  private let sessionID: SessionID
  private let workingDirectoryPath: String
  private let discovery: any CodexSessionDiscovering
  private let record: RecordAgentResumeIdentifier
  private let accumulator: CodexTerminalIdentifierAccumulator
  private let timeout: Duration
  private let persistenceWindow: Duration
  private let retryInterval: Duration

  private var launch: CodexLaunch?
  /// Whether `launch` is still registered as waiting for its session.
  private var isWaiting = false
  /// Whether the rollout is still being looked for.
  private var isDiscovering = false
  private var captured: String?
  /// What the rollout or the terminal found, while it is being written.
  private var pending: String?
  /// What the agent's hook last named. Once set, nothing else is written.
  private var named: String?
  /// What the rollout or the terminal found for this launch, if anything.
  private var found: String?
  private var watcher: Task<Void, Never>?
  private var persister: Task<Void, Never>?
  /// The last look of `finish`, awaited by every call that follows the first.
  private var finishing: Task<Void, Never>?
  private var queued: [String] = []
  private var queuedByteCount = 0
  private var draining = false

  /// The identifier this launch revealed but could not store, once retrying gave up.
  ///
  /// Reported rather than swallowed: a session whose identifier is lost can never be resumed,
  /// and that must not look like a session that simply never revealed one.
  public private(set) var unstoredIdentifier: String?

  public init(
    sessionID: SessionID,
    workingDirectoryPath: String,
    discovery: any CodexSessionDiscovering,
    record: RecordAgentResumeIdentifier,
    accumulator: CodexTerminalIdentifierAccumulator = CodexTerminalIdentifierAccumulator(),
    timeout: Duration = CodexSessionIdentifierCapture.defaultTimeout,
    persistenceWindow: Duration = CodexSessionIdentifierCapture.defaultPersistenceWindow,
    retryInterval: Duration = .milliseconds(200)
  ) {
    self.sessionID = sessionID
    self.workingDirectoryPath = workingDirectoryPath
    self.discovery = discovery
    self.record = record
    self.accumulator = accumulator
    self.timeout = timeout
    self.persistenceWindow = persistenceWindow
    self.retryInterval = retryInterval
  }

  /// Starts looking for the rollout of the session this launch began, for `timeout` at most.
  public func start(launchedAt: Date = Date()) async {
    guard launch == nil, captured == nil, pending == nil, named == nil else { return }
    let launch = CodexLaunch(workingDirectoryPath: workingDirectoryPath, launchedAt: launchedAt)
    self.launch = launch
    isWaiting = true
    isDiscovering = true
    await discovery.beginWaiting(launch)
    // The process may have ended, or named its session, while the launch was being registered:
    // its end may then have reached the registry first, and is told again.
    guard isWaiting, isDiscovering else {
      if !isWaiting { await discovery.endWaiting(launch) }
      return
    }
    watcher = Task { [discovery, timeout] in
      let identifier = await discovery.discoverSessionIdentifier(for: launch, timeout: timeout)
      await self.discoveryEnded(with: Task.isCancelled ? nil : identifier)
    }
  }

  private func discoveryEnded(with identifier: String?) async {
    isDiscovering = false
    guard let identifier else { return }
    await store(identifier, from: .rollout)
  }

  /// Feeds one decoded read of the terminal to the identifier accumulator, in order.
  ///
  /// The reads are queued before anything suspends, and a single drain consumes them: the
  /// accumulator splices an identifier straddling two reads, so handing it the second read
  /// first would splice the wrong halves and lose the identifier for the whole launch.
  ///
  /// Answers `.enough` once the identifier is known, from the terminal or elsewhere: nothing the
  /// terminal writes afterwards is read (#248).
  @discardableResult
  public func observe(output text: String) async -> AgentOutputDemand {
    guard captured == nil, pending == nil, named == nil else { return .enough }
    queued.append(text)
    queuedByteCount += text.utf8.count
    // A pane can write faster than the accumulator drains. Older reads go first: the
    // accumulator only ever keeps a tail of them anyway.
    while queuedByteCount > Self.maximumQueuedByteCount, queued.count > 1 {
      queuedByteCount -= queued.removeFirst().utf8.count
    }
    // The drain under way reads this one too.
    guard !draining else { return .more }

    draining = true
    defer { draining = false }
    while !queued.isEmpty, captured == nil, pending == nil, named == nil {
      let next = queued.removeFirst()
      queuedByteCount -= next.utf8.count
      guard let identifier = await accumulator.consume(next) else { continue }
      await store(identifier, from: .terminal)
    }
    queued.removeAll()
    queuedByteCount = 0
    return captured == nil && pending == nil && named == nil ? .more : .enough
  }

  /// The agent named its session through its hook (#144): stored, in place of whatever another
  /// source found, and every other watch ends. A later name — a new conversation begun in the
  /// same process — replaces it in turn.
  public func named(_ identifier: String) async {
    guard UUID(uuidString: identifier) != nil, identifier != named else { return }
    named = identifier
    pending = nil
    unstoredIdentifier = nil
    persister?.cancel()
    persister = nil
    await discovery.claim(identifier)
    // What the rollout suggested was another launch's after all: it is theirs to find.
    if let found, found != identifier {
      self.found = nil
      await discovery.release(found)
    }
    await stopWatching()

    switch await persist(identifier, from: .hook) {
    case .kept, .rejected:
      return
    case .retry:
      persister = Task { [weak self] in await self?.keepTrying(identifier, from: .hook) }
    }
  }

  /// Stops looking for an identifier. A write already under way is left to finish: the pane may
  /// be gone, the session it opened is not.
  public func stop() async {
    await stopWatching()
  }

  /// The process ended: the watch stops, after one last look for a rollout written just before —
  /// a first message sent as the agent quit is a conversation to resume all the same.
  ///
  /// The end is reported more than once, and every call returns only once that last look is over.
  public func finish() async {
    if let finishing {
      await finishing.value
      return
    }
    watcher?.cancel()
    watcher = nil
    isDiscovering = false
    let last = Task<Void, Never> { [weak self] in await self?.lookOnceMore() }
    finishing = last
    await last.value
  }

  /// Made whether or not the watch was still running: a first message sent after the half minute
  /// of a launch with hooks, just before the agent quit, may have left its hook unread.
  private func lookOnceMore() async {
    if let launch, captured == nil, pending == nil, named == nil,
      let identifier = await discovery.discoverSessionIdentifier(for: launch, timeout: .zero)
    {
      await store(identifier, from: .rollout)
    }
    await stopWatching()
  }

  private func stopWatching() async {
    watcher?.cancel()
    watcher = nil
    isDiscovering = false
    guard isWaiting, let launch else { return }
    isWaiting = false
    await discovery.endWaiting(launch)
  }

  public var identifier: String? {
    captured
  }

  /// Whether the rollout is still being looked for, for the tests.
  var isWatchingRollouts: Bool {
    isDiscovering
  }

  /// The session the agent named and that is not stored yet: what an instance that adopts the
  /// process from the terminal host still has to write (#141, #144).
  public var awaitedIdentifier: String? {
    guard let named, captured != named else { return nil }
    return named
  }

  /// Waits for a pending write to settle and returns what was stored.
  public func settled() async -> String? {
    await persister?.value
    return captured
  }

  private func store(_ identifier: String, from source: Source) async {
    guard captured == nil, pending == nil, named == nil else { return }
    pending = identifier
    found = identifier
    // The rollout watcher claimed it already, and calls this as it ends; cancelling it from inside
    // its own task would only cancel the work that follows.
    if source == .terminal {
      await discovery.claim(identifier)
      watcher?.cancel()
    }
    watcher = nil
    await stopWatching()

    switch await persist(identifier, from: source) {
    case .kept, .rejected:
      return
    case .retry:
      persister = Task { [weak self] in await self?.keepTrying(identifier, from: source) }
    }
  }

  /// Whether `identifier`, found by `source`, is still the one to write.
  private func isCurrent(_ identifier: String, from source: Source) -> Bool {
    source == .hook ? named == identifier : named == nil && pending == identifier
  }

  /// Retries until the session is ready to carry the identifier, or the window closes.
  ///
  /// The session may not exist yet, or may not have its agent configuration attached, when the
  /// rollout file shows up a fraction of a second after the launch.
  private func keepTrying(_ identifier: String, from source: Source) async {
    let deadline = ContinuousClock.now.advanced(by: persistenceWindow)
    while ContinuousClock.now < deadline {
      do {
        try await Task.sleep(for: retryInterval)
      } catch {
        break
      }
      guard isCurrent(identifier, from: source) else { return }
      switch await persist(identifier, from: source) {
      case .kept, .rejected:
        return
      case .retry:
        continue
      }
    }
    guard isCurrent(identifier, from: source), captured != identifier else { return }
    if source != .hook { pending = nil }
    unstoredIdentifier = identifier
  }

  private func persist(_ identifier: String, from source: Source) async -> Persistence {
    guard isCurrent(identifier, from: source) else { return .rejected }
    let outcome: RecordAgentResumeIdentifierOutcome
    do {
      outcome = try await record(sessionID: sessionID, identifier: identifier)
    } catch {
      return .retry
    }
    // The hook named the session while this was being written, and its own write may have landed
    // first: it is written again, so that the agent's word is the last one.
    guard isCurrent(identifier, from: source) else {
      if let named, outcome.isPersisted {
        if (try? await record(sessionID: sessionID, identifier: named))?.isPersisted == true,
          self.named == named
        {
          captured = named
        }
      }
      return .rejected
    }
    if outcome.isPersisted {
      captured = identifier
      if source != .hook { pending = nil }
      unstoredIdentifier = nil
      return .kept
    }
    return outcome.isRetryable ? .retry : .rejected
  }
}
