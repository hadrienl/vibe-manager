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
  private var tail = ""
  private var found: String?

  public init(extractor: CodexResumeIdentifierExtractor = CodexResumeIdentifierExtractor()) {
    self.extractor = extractor
  }

  public var identifier: String? {
    found
  }

  /// - Returns: the identifier the first time one is recognised, `nil` afterwards.
  @discardableResult
  public func consume(_ text: String) -> String? {
    guard found == nil else { return nil }

    let combined = tail + text
    let hasCompleteTail = combined.last.map(\.isNewline) ?? false
    var lines = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map(String.init)
    tail = hasCompleteTail ? "" : (lines.popLast() ?? "")
    if tail.utf8.count > Self.maximumTailByteCount {
      tail = String(tail.suffix(Self.maximumTailByteCount))
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
  /// Codex writes its rollout as it starts. Past this delay, waiting only keeps a task alive
  /// for a session that will never be resumable.
  public static let defaultTimeout: Duration = .seconds(30)

  private let sessionID: SessionID
  private let workingDirectoryPath: String
  private let discovery: any CodexSessionDiscovering
  private let record: RecordAgentResumeIdentifier
  private let accumulator: CodexTerminalIdentifierAccumulator
  private let timeout: Duration

  private var captured: String?
  private var watcher: Task<Void, Never>?

  public init(
    sessionID: SessionID,
    workingDirectoryPath: String,
    discovery: any CodexSessionDiscovering,
    record: RecordAgentResumeIdentifier,
    accumulator: CodexTerminalIdentifierAccumulator = CodexTerminalIdentifierAccumulator(),
    timeout: Duration = CodexSessionIdentifierCapture.defaultTimeout
  ) {
    self.sessionID = sessionID
    self.workingDirectoryPath = workingDirectoryPath
    self.discovery = discovery
    self.record = record
    self.accumulator = accumulator
    self.timeout = timeout
  }

  /// Starts watching the rollout directory. Call it when the terminal process starts.
  public func start(launchedAt: Date = Date()) {
    guard watcher == nil, captured == nil else { return }
    watcher = Task { [discovery, workingDirectoryPath, timeout] in
      let identifier = await discovery.discoverSessionIdentifier(
        workingDirectoryPath: workingDirectoryPath,
        since: launchedAt,
        timeout: timeout
      )
      // A watch that was stopped must not write: the terminal is gone, and a discovery that
      // answered while being cancelled describes a session nobody is looking at any more.
      guard let identifier, !Task.isCancelled else { return }
      await self.store(identifier)
    }
  }

  /// Feeds a chunk of terminal output, decoded by the caller.
  public func observe(output text: String) async {
    guard captured == nil else { return }
    guard let identifier = await accumulator.consume(text) else { return }
    await store(identifier)
  }

  /// Stops the rollout watch. Call it when the terminal process ends.
  public func stop() {
    watcher?.cancel()
    watcher = nil
  }

  public var identifier: String? {
    captured
  }

  private func store(_ identifier: String) async {
    guard captured == nil else { return }
    captured = identifier
    watcher?.cancel()
    watcher = nil
    // A failing store must not take the terminal down with it: the session simply stays
    // unresumable, which the next launch will report.
    _ = try? await record(sessionID: sessionID, identifier: identifier)
  }
}
