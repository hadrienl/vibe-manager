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
/// Two sources race: the rollout file Codex writes, which is reliable, and the terminal
/// output, which is immediate but only as stable as the interface. The first to produce an
/// identifier wins, and nothing overwrites it for the rest of the launch — a false positive
/// read from the screen must not replace what the rollout established, and the other way
/// round. A later launch of the same work session does replace it: that is a new conversation.
public actor CodexSessionIdentifierCapture {
  public static let defaultTimeout: Duration = .seconds(30)
  public static let defaultPersistenceWindow: Duration = .seconds(30)
  /// How much terminal output may wait to be accumulated before the oldest read is dropped.
  static let maximumQueuedByteCount = 256 * 1024

  private enum Source {
    case rollout
    case terminal
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

  private var captured: String?
  private var pending: String?
  private var watcher: Task<Void, Never>?
  private var persister: Task<Void, Never>?
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

  public func start(launchedAt: Date = Date()) {
    guard watcher == nil, captured == nil, pending == nil else { return }
    watcher = Task { [discovery, workingDirectoryPath, timeout] in
      let identifier = await discovery.discoverSessionIdentifier(
        workingDirectoryPath: workingDirectoryPath,
        since: launchedAt,
        timeout: timeout
      )
      guard let identifier, !Task.isCancelled else { return }
      await self.store(identifier, from: .rollout)
    }
  }

  /// Feeds one decoded read of the terminal to the identifier accumulator, in order.
  ///
  /// The reads are queued before anything suspends, and a single drain consumes them: the
  /// accumulator splices an identifier straddling two reads, so handing it the second read
  /// first would splice the wrong halves and lose the identifier for the whole launch.
  public func observe(output text: String) async {
    guard captured == nil, pending == nil else { return }
    queued.append(text)
    queuedByteCount += text.utf8.count
    // A pane can write faster than the accumulator drains. Older reads go first: the
    // accumulator only ever keeps a tail of them anyway.
    while queuedByteCount > Self.maximumQueuedByteCount, queued.count > 1 {
      queuedByteCount -= queued.removeFirst().utf8.count
    }
    guard !draining else { return }

    draining = true
    defer { draining = false }
    while !queued.isEmpty, captured == nil, pending == nil {
      let next = queued.removeFirst()
      queuedByteCount -= next.utf8.count
      guard let identifier = await accumulator.consume(next) else { continue }
      await store(identifier, from: .terminal)
    }
    queued.removeAll()
    queuedByteCount = 0
  }

  /// Stops looking for an identifier. A write already under way is left to finish: the pane may
  /// be gone, the session it opened is not.
  public func stop() {
    watcher?.cancel()
    watcher = nil
  }

  public var identifier: String? {
    captured
  }

  /// Waits for a pending write to settle and returns what was stored.
  public func settled() async -> String? {
    await persister?.value
    return captured
  }

  private func store(_ identifier: String, from source: Source) async {
    guard captured == nil, pending == nil else { return }
    pending = identifier
    // The rollout watcher calls this as it ends; cancelling it from inside its own task would
    // only cancel the work that follows.
    if source == .terminal { watcher?.cancel() }
    watcher = nil

    switch await persist(identifier) {
    case .kept, .rejected:
      return
    case .retry:
      persister = Task { [weak self] in await self?.keepTrying(identifier) }
    }
  }

  /// Retries until the session is ready to carry the identifier, or the window closes.
  ///
  /// The session may not exist yet, or may not have its agent configuration attached, when the
  /// rollout file shows up a fraction of a second after the launch.
  private func keepTrying(_ identifier: String) async {
    let deadline = ContinuousClock.now.advanced(by: persistenceWindow)
    while ContinuousClock.now < deadline {
      do {
        try await Task.sleep(for: retryInterval)
      } catch {
        break
      }
      switch await persist(identifier) {
      case .kept, .rejected:
        return
      case .retry:
        continue
      }
    }
    guard captured == nil else { return }
    pending = nil
    unstoredIdentifier = identifier
  }

  private func persist(_ identifier: String) async -> Persistence {
    guard captured == nil else { return .kept }
    let outcome: RecordAgentResumeIdentifierOutcome
    do {
      outcome = try await record(sessionID: sessionID, identifier: identifier)
    } catch {
      return .retry
    }
    if outcome.isPersisted {
      captured = identifier
      pending = nil
      unstoredIdentifier = nil
      return .kept
    }
    return outcome.isRetryable ? .retry : .rejected
  }
}
