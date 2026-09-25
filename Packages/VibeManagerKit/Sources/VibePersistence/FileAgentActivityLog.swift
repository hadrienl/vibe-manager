import Darwin
import Foundation
import VibeApplication
import VibeDomain

/// `AgentActivity/<session id>.log`: where each session's agent appends what it does (#45).
///
/// A file rather than a socket, because an agent can outlive the application (ADR 0017): what it
/// does while nobody listens is precisely what has to be read back at the next launch. Appending
/// never blocks the hook that writes, and nothing has to be running for the write to succeed.
///
/// The application only ever renames or removes a log, never truncates one: a hook may hold it
/// open at any moment, and a truncation would land its line in the middle of nothing.
public actor FileAgentActivityLog: AgentActivityLogStore {
  /// Past this size, once everything in it has been read, a log is moved aside and started anew.
  public static let rotationThreshold: UInt64 = 1024 * 1024

  private let directory: URL
  private let rotationThreshold: UInt64

  public init(
    directory: URL = FileAgentActivityLog.defaultDirectory(),
    rotationThreshold: UInt64 = FileAgentActivityLog.rotationThreshold
  ) {
    self.directory = directory
    self.rotationThreshold = rotationThreshold
  }

  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("AgentActivity", isDirectory: true)
  }

  public func prepareLog(for id: SessionID) throws -> URL {
    let url = logURL(for: id)
    let manager = FileManager.default
    if !manager.fileExists(atPath: directory.path) {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    // What a previous process reported is over: its reader was stopped with it.
    try? manager.removeItem(at: url)
    try? manager.removeItem(at: Self.rotatedURL(of: url))
    guard
      manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteNoPermission) }
    return url
  }

  public func existingLog(for id: SessionID) -> URL? {
    let url = logURL(for: id)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  public func events(
    for id: SessionID,
    from position: AgentActivityLogPosition?
  ) -> AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)> {
    let (stream, continuation) = AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>
      .makeStream(bufferingPolicy: .unbounded)
    let follower = AgentActivityLogFollower(
      url: logURL(for: id), rotationThreshold: rotationThreshold, continuation: continuation)
    continuation.onTermination = { _ in follower.stop() }
    follower.start(from: position)
    return stream
  }

  public func removeLog(for id: SessionID) {
    let url = logURL(for: id)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: Self.rotatedURL(of: url))
  }

  private func logURL(for id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).log", isDirectory: false)
  }

  static func rotatedURL(of url: URL) -> URL {
    url.appendingPathExtension("1")
  }
}

/// Reads one log as it grows, across its rotations. Everything it does happens on its own queue.
final class AgentActivityLogFollower: @unchecked Sendable {
  /// A line longer than this is not one a hook wrote: it is dropped rather than accumulated.
  static let maximumLineLength = 64 * 1024
  /// How often a log that is not there yet — or not there any more — is looked for again.
  static let retryInterval: DispatchTimeInterval = .milliseconds(250)

  private let url: URL
  private let rotationThreshold: UInt64
  private let continuation: AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>.Continuation
  private let queue = DispatchQueue(label: "com.hadrienl.VibeManager.agent-activity-log")

  private var descriptor: Int32 = -1
  private var fileIdentifier: UInt64 = 0
  private var offset: UInt64 = 0
  private var pending = Data()
  private var source: (any DispatchSourceFileSystemObject)?
  private var isStopped = false

  init(
    url: URL,
    rotationThreshold: UInt64,
    continuation: AsyncStream<(AgentActivityEvent, AgentActivityLogPosition)>.Continuation
  ) {
    self.url = url
    self.rotationThreshold = rotationThreshold
    self.continuation = continuation
  }

  func start(from position: AgentActivityLogPosition?) {
    queue.async { self.open(resumingAt: position) }
  }

  func stop() {
    queue.async {
      self.isStopped = true
      self.close()
    }
  }

  private func open(resumingAt position: AgentActivityLogPosition?) {
    guard !isStopped else { return }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      queue.asyncAfter(deadline: .now() + Self.retryInterval) { self.open(resumingAt: nil) }
      return
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      Darwin.close(descriptor)
      queue.asyncAfter(deadline: .now() + Self.retryInterval) { self.open(resumingAt: nil) }
      return
    }
    self.descriptor = descriptor
    fileIdentifier = UInt64(status.st_ino)
    pending = Data()
    // A position is only good for the file it was taken in, and only if the file still reaches it.
    if let position, position.fileIdentifier == fileIdentifier,
      position.offset <= UInt64(status.st_size)
    {
      offset = position.offset
    } else {
      offset = 0
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke],
      queue: queue)
    source.setEventHandler { [weak self] in
      guard let self, let source = self.source else { return }
      self.drain()
      let event = source.data
      if !event.intersection([.delete, .rename, .revoke]).isEmpty {
        self.reopen()
      } else {
        self.rotateIfNeeded()
      }
    }
    self.source = source
    source.resume()
    drain()
    rotateIfNeeded()
  }

  /// The file was moved aside or removed: what it still held has been read, and the next one —
  /// created by the next hook — is followed from its start.
  private func reopen() {
    let rotated = AgentActivityLogFollower.rotatedURL(of: url)
    close()
    // A hook that opened the old file before the rename may still be writing to it: its line is
    // given a moment to land before the file is dropped.
    queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
      try? FileManager.default.removeItem(at: rotated)
      self.open(resumingAt: nil)
    }
  }

  private func rotateIfNeeded() {
    guard descriptor >= 0, offset >= rotationThreshold, pending.isEmpty else { return }
    // The next event on the descriptor reports the rename, and `reopen` takes it from there.
    try? FileManager.default.moveItem(
      at: url, to: AgentActivityLogFollower.rotatedURL(of: url))
  }

  private func close() {
    source?.cancel()
    source = nil
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  private func drain() {
    guard descriptor >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(descriptor, bytes.baseAddress, bytes.count, off_t(offset + UInt64(pending.count)))
      }
      guard count > 0 else { break }
      pending.append(contentsOf: buffer[0..<count])
      consumeLines()
    }
  }

  private func consumeLines() {
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = pending[pending.startIndex..<newline]
      let length = UInt64(newline - pending.startIndex + 1)
      pending = Data(pending[(newline + 1)...])
      offset += length
      if let event = Self.parse(line) {
        continuation.yield(
          (event, AgentActivityLogPosition(fileIdentifier: fileIdentifier, offset: offset)))
      }
    }
    if pending.count > Self.maximumLineLength {
      offset += UInt64(pending.count)
      pending = Data()
    }
  }

  /// `name ⇥ seconds since 1970 ⇥ payload`. Anything else is not a line a hook wrote.
  static func parse(_ line: Data) -> AgentActivityEvent? {
    let fields = line.split(separator: 0x09, maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count >= 2,
      let name = String(data: fields[0], encoding: .utf8), !name.isEmpty,
      let seconds = String(data: fields[1], encoding: .utf8).flatMap(TimeInterval.init)
    else { return nil }
    let payload = fields.count == 3 && !fields[2].isEmpty ? Data(fields[2]) : nil
    return AgentActivityEvent(
      name: name, date: Date(timeIntervalSince1970: seconds), payload: payload)
  }

  static func rotatedURL(of url: URL) -> URL {
    FileAgentActivityLog.rotatedURL(of: url)
  }
}
