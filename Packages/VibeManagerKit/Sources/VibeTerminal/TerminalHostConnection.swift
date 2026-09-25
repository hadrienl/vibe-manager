import Darwin
import Dispatch
import Foundation

/// The Unix-domain socket calls, kept to the few the host and its client need — and the web view's
/// channel (#69), which lives in the same private directory.
public enum UnixSocket {
  /// `sun_path` is 104 bytes on Darwin, terminator included.
  public static let maximumPathLength = 103

  public static func listen(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Self.lastError() }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    do {
      try withAddress(path) { address, length in
        guard bind(descriptor, address, length) == 0 else { throw Self.lastError() }
      }
      // Owner only, on top of the private directory it sits in.
      chmod(path, 0o600)
      guard Darwin.listen(descriptor, 16) == 0 else { throw Self.lastError() }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func lastError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  /// A connected descriptor, or `nil` when nothing listens there.
  public static func connect(to path: String) -> Int32? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let connected =
      (try? withAddress(path) { address, length in
        Darwin.connect(descriptor, address, length) == 0
      }) ?? false
    guard connected else {
      close(descriptor)
      return nil
    }
    return descriptor
  }

  /// The user on the other end of a connected socket.
  public static func peerUserIdentifier(of descriptor: Int32) -> uid_t? {
    var user: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(descriptor, &user, &group) == 0 else { return nil }
    return user
  }

  /// The audit token of the process on the other end, which — unlike its pid — cannot be worn by
  /// another process between the moment it is read and the moment its signature is checked.
  public static func peerAuditToken(of descriptor: Int32) -> audit_token_t? {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
      return nil
    }
    return token
  }

  private static func withAddress<Result>(
    _ path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
  ) throws -> Result {
    let bytes = Array(path.utf8)
    guard bytes.count <= maximumPathLength else { throw POSIXError(.ENAMETOOLONG) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
        try body(address, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }
}

/// One connection to or from the terminal host: frames in, frames out.
///
/// Reading runs on its own queue and hands whole frames to a single stream, so they are consumed
/// in the order they arrived. Writing runs on another serial queue, so frames leave in the order
/// they were sent — a keystroke never overtakes the resize typed before it — and a peer that stops
/// reading blocks the writer, never the reader.
final class TerminalHostConnection: @unchecked Sendable {
  private static let readBufferSize = 64 * 1_024
  /// How long a closing connection waits for a peer that reads nothing, before dropping the rest.
  private static let drainLimit: Duration = .seconds(2)

  let descriptor: Int32
  let frames: AsyncStream<TerminalHostFrame>

  private let continuation: AsyncStream<TerminalHostFrame>.Continuation
  private let readQueue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal-host.read")
  private let writeQueue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal-host.write")
  private let source: DispatchSourceRead
  private let lock = NSLock()
  private var isClosed = false
  /// Set while closing: until then a peer that reads nothing is waited for, since it may only be
  /// paused — the application under a debugger — and giving up would read as its crash.
  private var drainDeadline: ContinuousClock.Instant?
  /// Only ever touched on the read queue.
  private var decoder = TerminalHostFrameDecoder()

  init(descriptor: Int32) {
    self.descriptor = descriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    // A peer that has gone away must be an error to handle, never a `SIGPIPE` that ends the
    // process — the application's as much as the host's.
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var streamContinuation: AsyncStream<TerminalHostFrame>.Continuation?
    frames = AsyncStream { streamContinuation = $0 }
    guard let streamContinuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    continuation = streamContinuation
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)

    source.setEventHandler { [weak self] in
      self?.readAvailableBytes()
    }
    // Closed once nothing can write to it any more: a descriptor closed under a pending write
    // could be reused by the next socket and receive bytes meant for this one.
    source.setCancelHandler { [writeQueue] in
      writeQueue.sync {}
      Darwin.close(descriptor)
    }
    source.resume()
  }

  /// Queues a frame and returns at once. Order with every other send is kept.
  func send(_ frame: TerminalHostFrame) {
    let bytes = frame.encoded
    writeQueue.async { [weak self] in
      self?.writeAll(bytes)
    }
  }

  /// Queues a frame and returns once it has left, or once the connection is known to be gone.
  @discardableResult
  func sendAndWait(_ frame: TerminalHostFrame) async -> Bool {
    let bytes = frame.encoded
    return await withCheckedContinuation { continuation in
      writeQueue.async { [weak self] in
        continuation.resume(returning: self?.writeAll(bytes) ?? false)
      }
    }
  }

  /// Ends the connection once every frame already sent has left — or could not, within its bound.
  ///
  /// `close()` alone drops what is still queued, and the frame a departure is made of is the last
  /// one queued: a goodbye cut off by its own close reads, to the host, as the crash of its
  /// client, and it stops the agents it was just asked to keep.
  func closeAfterPendingWrites() async {
    lock.withLock { drainDeadline = ContinuousClock.now + Self.drainLimit }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writeQueue.async { continuation.resume() }
    }
    close()
  }

  /// Ends the connection in both directions, dropping whatever is still queued. The stream of
  /// frames finishes when the reader sees it.
  func close() {
    lock.lock()
    let wasClosed = isClosed
    isClosed = true
    lock.unlock()
    guard !wasClosed else { return }
    // On the read queue, and only while the source still holds the descriptor: closed by an end
    // of file in the meantime, its number may already belong to another socket.
    readQueue.async { [weak self] in
      guard let self, !self.source.isCancelled else { return }
      shutdown(self.descriptor, SHUT_RDWR)
      self.finish()
    }
  }

  private var closed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isClosed
  }

  @discardableResult
  private func writeAll(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      guard !closed else { return false }
      let written = bytes[offset...].withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress, buffer.count)
      }
      if written > 0 {
        offset += written
        continue
      }
      switch errno {
      case EINTR:
        continue
      case EAGAIN:
        // The peer is not reading. Waiting here is the back pressure: the writer is its own queue,
        // so nothing else stalls behind it. Once closing, not for ever: the departure must leave.
        if let deadline = lock.withLock({ drainDeadline }), ContinuousClock.now > deadline {
          close()
          return false
        }
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        _ = poll(&descriptorSet, 1, 250)
      default:
        close()
        return false
      }
    }
    return true
  }

  private func readAvailableBytes() {
    var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
    while true {
      let count = buffer.withUnsafeMutableBytes { pointer in
        read(descriptor, pointer.baseAddress, Self.readBufferSize)
      }
      if count > 0 {
        do {
          for frame in try decoder.append(buffer[0..<count]) {
            continuation.yield(frame)
          }
        } catch {
          // A frame that cannot be read means the two ends no longer agree on where frames begin,
          // and nothing after it can be trusted either.
          finish()
          return
        }
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN { return }
      finish()
      return
    }
  }

  /// On the read queue only.
  private func finish() {
    lock.lock()
    isClosed = true
    lock.unlock()
    guard !source.isCancelled else { return }
    source.cancel()
    continuation.finish()
  }
}
