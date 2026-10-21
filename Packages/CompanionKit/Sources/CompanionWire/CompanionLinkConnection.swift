#if os(macOS)
  import Darwin
  import Dispatch
  import Foundation

  /// The Unix-domain socket calls the link needs, the same as the terminal host's
  /// (`VibeTerminal.UnixSocket`), which this package cannot depend on.
  public enum CompanionSocket {
    /// `sun_path` is 104 bytes on Darwin, terminator included.
    public static let maximumPathLength = 103

    public static func listen(at path: String) throws -> Int32 {
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw lastError() }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      // Non-blocking: a read source may fire once more than there are connections waiting, and a
      // blocking `accept` would then hold its caller — the link's actor — for good.
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
      do {
        try withAddress(path) { address, length in
          guard bind(descriptor, address, length) == 0 else { throw lastError() }
        }
        // Owner only, on top of the private directory it sits in.
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 4) == 0 else { throw lastError() }
        return descriptor
      } catch {
        close(descriptor)
        throw error
      }
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

    /// The audit token of the process on the other end, which — unlike its pid — cannot be worn
    /// by another process between the moment it is read and the moment its signature is checked.
    public static func peerAuditToken(of descriptor: Int32) -> audit_token_t? {
      var token = audit_token_t()
      var length = socklen_t(MemoryLayout<audit_token_t>.size)
      guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
        return nil
      }
      return token
    }

    private static func lastError() -> POSIXError {
      POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

  /// One end of the link: messages in, messages out.
  ///
  /// Reading runs on its own queue and hands whole messages to a single stream, in the order they
  /// arrived; writing runs on another serial queue, so messages leave in the order they were sent.
  /// The traffic is a few messages a minute: none of the host's back pressure is needed.
  public final class CompanionLinkConnection: @unchecked Sendable {
    private static let readBufferSize = 64 * 1_024

    public let messages: AsyncStream<CompanionLinkMessage>

    private let descriptor: Int32
    private let continuation: AsyncStream<CompanionLinkMessage>.Continuation
    private let readQueue = DispatchQueue(label: "eu.hadrien.VibeManager.companion-link.read")
    private let writeQueue = DispatchQueue(label: "eu.hadrien.VibeManager.companion-link.write")
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var isClosed = false
    /// Only ever touched on the read queue.
    private var decoder = CompanionLinkDecoder()

    public init(descriptor: Int32) {
      self.descriptor = descriptor
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
      // A peer that has gone away is an error to handle, never a `SIGPIPE` that ends the process.
      var on: Int32 = 1
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      (messages, continuation) = AsyncStream.makeStream()
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

    /// Queues a message and returns at once.
    public func send(_ message: CompanionLinkMessage) {
      let bytes = CompanionLinkFrame.encode(message)
      writeQueue.async { [weak self] in
        self?.writeAll(bytes)
      }
    }

    /// Ends the connection in both directions. The stream of messages finishes.
    public func close() {
      let wasClosed = lock.withLock {
        defer { isClosed = true }
        return isClosed
      }
      guard !wasClosed else { return }
      readQueue.async { [weak self] in
        guard let self, !self.source.isCancelled else { return }
        shutdown(self.descriptor, SHUT_RDWR)
        self.finish()
      }
    }

    private var closed: Bool {
      lock.withLock { isClosed }
    }

    private func writeAll(_ bytes: [UInt8]) {
      var offset = 0
      while offset < bytes.count {
        guard !closed else { return }
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
          var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          _ = poll(&descriptorSet, 1, 250)
        default:
          close()
          return
        }
      }
    }

    private func readAvailableBytes() {
      var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
      while true {
        let count = buffer.withUnsafeMutableBytes { pointer in
          read(descriptor, pointer.baseAddress, Self.readBufferSize)
        }
        if count > 0 {
          do {
            for message in try decoder.append(buffer[0..<count]) {
              continuation.yield(message)
            }
          } catch {
            // The two ends no longer agree on where frames begin: nothing after can be trusted.
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
      lock.withLock { isClosed = true }
      guard !source.isCancelled else { return }
      source.cancel()
      continuation.finish()
    }
  }
#endif
