import Darwin
import Foundation
import VibeApplication
import VibeDomain
import VibeProcess
import VibeTerminal

/// The first words on the channel, before any MCP message (#69).
enum BrowserChannelHandshake {
  static let protocolVersion = 1
  /// A line longer than this closes the connection: a screenshot is well under it.
  static let lineLimit = 16 * 1024 * 1024

  static func hello() -> Data {
    BrowserMCPServer.line(["vibe": "hello", "protocol": .number(Double(protocolVersion))])
  }

  static func welcome() -> Data {
    BrowserMCPServer.line(["vibe": "welcome", "protocol": .number(Double(protocolVersion))])
  }

  static func refused(_ reason: String) -> Data {
    BrowserMCPServer.line(["vibe": "refused", "reason": .string(reason)])
  }
}

/// Reads a descriptor line by line, on the calling thread.
/// Handed from the thread that connects to the one that reads, never used by two at once.
final class LineReader: @unchecked Sendable {
  private let descriptor: Int32
  private var buffer = Data()
  private var isAtEnd = false

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  /// The next line without its newline, or `nil` at the end or past the limit.
  func next() -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer = Data(buffer[(newline + 1)...])
        return Data(line)
      }
      guard !isAtEnd, buffer.count < BrowserChannelHandshake.lineLimit else { return nil }
      var chunk = [UInt8](repeating: 0, count: 64 * 1024)
      let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count < 0, errno == EINTR { continue }
      if count <= 0 {
        isAtEnd = true
        if buffer.isEmpty { return nil }
        let line = buffer
        buffer = Data()
        return line
      }
      buffer.append(contentsOf: chunk[0..<count])
    }
  }
}

func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
      if written < 0, errno == EINTR { continue }
      guard written > 0 else { return false }
      offset += written
    }
    return true
  }
}

/// The application's end of the channel: a socket the agents' bridges and the `vibe` command
/// connect to, in the terminal host's private directory (#69).
///
/// A connection is accepted for one session: the one whose terminal the connecting process
/// descends from (`BrowserChannelAuthorizer`). Nothing else is asked of it — no secret, no
/// signature: whatever runs in a session's terminal speaks for that session's agent, and nothing
/// else can.
@MainActor
public final class BrowserChannelListener {
  private let socketPath: String
  private let prepare: () throws -> Void
  private let runner: any BrowserToolRunning
  private let sessions: @MainActor () async -> [SessionProcess]
  private var listener: Int32 = -1
  private var source: (any DispatchSourceRead)?

  public init(
    socketPath: String,
    prepare: @escaping () throws -> Void,
    runner: any BrowserToolRunning,
    sessions: @escaping @MainActor () async -> [SessionProcess]
  ) {
    self.socketPath = socketPath
    self.prepare = prepare
    self.runner = runner
    self.sessions = sessions
  }

  public func start() throws {
    guard listener < 0 else { return }
    try prepare()
    // A socket something still listens on belongs to another copy running on the same data: it
    // keeps it. One nobody answers on was left by a run that ended, and is replaced.
    if let other = UnixSocket.connect(to: socketPath) {
      close(other)
      throw POSIXError(.EADDRINUSE)
    }
    unlink(socketPath)
    let descriptor = try UnixSocket.listen(at: socketPath)
    listener = descriptor
    source = Self.acceptSource(on: descriptor) { [weak self] client in
      guard let self else {
        close(client)
        return
      }
      await self.admit(client)
    }
  }

  /// Accepts on a queue of its own. Built outside the main actor on purpose: a closure written in
  /// an isolated method is isolated too, and would trap when the queue runs it.
  private nonisolated static func acceptSource(
    on descriptor: Int32, admit: @escaping @MainActor @Sendable (Int32) async -> Void
  ) -> any DispatchSourceRead {
    let source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor, queue: DispatchQueue(label: "vibe.browser.accept"))
    source.setEventHandler {
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var noSignal: Int32 = 1
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      Task { @MainActor in await admit(client) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    return source
  }

  public func stop() {
    source?.cancel()
    source = nil
    listener = -1
    unlink(socketPath)
  }

  private func admit(_ client: Int32) async {
    guard UnixSocket.peerUserIdentifier(of: client) == getuid(),
      let token = UnixSocket.peerAuditToken(of: client)
    else {
      close(client)
      return
    }
    // The pid is read from the audit token, which the kernel filled in at connection time.
    let processIdentifier = pid_t(bitPattern: token.val.5)
    let lineage = ProcessAncestry.lineage(of: processIdentifier).map {
      ProcessLineageEntry(
        processIdentifier: $0.processIdentifier,
        parentProcessIdentifier: $0.parentProcessIdentifier,
        startedAt: ProcessStartTime(seconds: $0.startSeconds, microseconds: $0.startMicroseconds))
    }
    let known = await sessions()
    let connection = BrowserChannelConnection(descriptor: client)
    guard let session = BrowserChannelAuthorizer.session(of: lineage, among: known) else {
      connection.refuse(
        "This process does not run in the terminal of a Vibe Manager session, "
          + "so it cannot drive a session's web view.")
      return
    }
    connection.serve { [weak self] line in
      guard let self else { return nil }
      return await self.respond(to: line, session: session)
    }
  }

  private func respond(to line: Data, session: SessionID) async -> Data? {
    if let hello = try? JSONDecoder().decode(JSONValue.self, from: line), hello["vibe"] != nil {
      return BrowserChannelHandshake.welcome()
    }
    return await BrowserMCPServer.respond(to: line, session: session, runner: runner)
  }
}

/// One accepted connection: lines in on a thread of their own, each answered on the main actor,
/// answers out in the order they are ready.
final class BrowserChannelConnection: @unchecked Sendable {
  private let descriptor: Int32
  private let writes = DispatchQueue(label: "vibe.browser.connection.write")
  private let lock = NSLock()
  private var isClosed = false

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func refuse(_ reason: String) {
    // The hello, if it came, is not waited for: the answer is the same.
    _ = writeAll(BrowserChannelHandshake.refused(reason), to: descriptor)
    close()
  }

  func serve(_ respond: @escaping @MainActor @Sendable (Data) async -> Data?) {
    Thread.detachNewThread { [self] in
      let reader = LineReader(descriptor: descriptor)
      while let line = reader.next() {
        guard !line.isEmpty else { continue }
        Task { @MainActor in
          guard let answer = await respond(line) else { return }
          self.write(answer)
        }
      }
      close()
    }
  }

  private func write(_ data: Data) {
    writes.async { [self] in
      guard !lock.withLock({ isClosed }) else { return }
      _ = writeAll(data, to: descriptor)
    }
  }

  private func close() {
    writes.async { [self] in
      let wasClosed = lock.withLock {
        defer { isClosed = true }
        return isClosed
      }
      if !wasClosed { Darwin.close(descriptor) }
    }
  }
}
