import Darwin
import Dispatch
import Foundation

// Writes run on their own queue: sharing the read queue would let a full input buffer stall the
// reader, and a child that stops reading its input because nobody drains its output deadlocks.
final class TerminalInputWriter: @unchecked Sendable {
  private static let pollTimeoutMilliseconds: Int32 = 100
  private static let maximumWaitedAttempts = 50

  private let descriptor: Int32
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isClosed = false

  init(descriptor: Int32) {
    self.descriptor = descriptor
    queue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal.write")
  }

  func write(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    queue.async { [weak self] in
      self?.writeSynchronously(bytes)
    }
  }

  // Waits for queued writes to drain so that the descriptor is never closed underneath one.
  func close() {
    lock.lock()
    isClosed = true
    lock.unlock()
    queue.sync {}
  }

  private func hasBeenClosed() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isClosed
  }

  private func writeSynchronously(_ bytes: [UInt8]) {
    guard !hasBeenClosed() else { return }

    var offset = 0
    var waitedAttempts = 0
    bytes.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      while offset < bytes.count {
        let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
        if written > 0 {
          offset += written
          continue
        }
        switch errno {
        case EINTR:
          continue
        case EAGAIN:
          // A blocked write means the child is not reading. Waiting is the only correct answer,
          // but it is bounded so that teardown never hangs on an unresponsive process.
          var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          if poll(&descriptorSet, 1, Self.pollTimeoutMilliseconds) < 0, errno != EINTR {
            return
          }
          waitedAttempts += 1
          guard waitedAttempts < Self.maximumWaitedAttempts, !hasBeenClosed() else { return }
        default:
          // EPIPE or EIO: the child is gone and the exit source reports the outcome.
          return
        }
      }
    }
  }
}
