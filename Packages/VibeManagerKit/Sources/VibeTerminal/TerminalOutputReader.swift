import Darwin
import Dispatch
import Foundation

enum TerminalReadEvent: Sendable {
  case bytes([UInt8])
  case endOfFile
}

// Reads the pseudo terminal master off the main actor, coalesces bursts into window-sized
// chunks and applies back pressure by suspending the read source rather than growing a buffer.
final class TerminalOutputReader: @unchecked Sendable {
  private static let readBufferSize = 64 * 1_024
  private static let coalescingWindow = DispatchTimeInterval.milliseconds(16)
  private static let highWaterMark = 4 * 1_024 * 1_024
  private static let lowWaterMark = 1 * 1_024 * 1_024

  private let descriptor: Int32
  private let queue: DispatchQueue
  private let source: DispatchSourceRead
  private let continuation: AsyncStream<TerminalReadEvent>.Continuation
  private let lock = NSLock()

  private var pending: [UInt8] = []
  private var isFlushScheduled = false
  private var outstandingByteCount = 0
  private var isSuspended = false
  private var isFinished = false
  private var isThrottling = true

  let events: AsyncStream<TerminalReadEvent>

  init(descriptor: Int32) {
    self.descriptor = descriptor
    queue = DispatchQueue(label: "com.hadrienl.VibeManager.terminal.read")
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)

    var streamContinuation: AsyncStream<TerminalReadEvent>.Continuation?
    events = AsyncStream { streamContinuation = $0 }
    guard let streamContinuation else {
      preconditionFailure("AsyncStream did not provide a continuation")
    }
    continuation = streamContinuation

    source.setEventHandler { [weak self] in
      self?.readAvailableBytes()
    }
    // The reader owns the master descriptor: closing it anywhere else could let a recycled
    // descriptor be read as if it belonged to this session.
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()
  }

  // Every suspend, resume and cancel of the dispatch source happens while the lock is
  // held, so the source can never be resumed before the matching suspend has landed.
  // None of those calls blocks or runs a handler inline, and the reader queue never
  // takes the lock around them, so holding it here cannot deadlock.
  func didConsume(byteCount: Int) {
    lock.lock()
    outstandingByteCount = max(0, outstandingByteCount - byteCount)
    if isSuspended, outstandingByteCount <= Self.lowWaterMark, !isFinished {
      isSuspended = false
      source.resume()
    }
    lock.unlock()
  }

  /// Reads on whatever the subscribers keep up with: a process being stopped cannot finish
  /// exiting while its output waits in the terminal, and the memory it costs ends with it.
  func stopThrottling() {
    lock.lock()
    isThrottling = false
    if isSuspended, !isFinished {
      isSuspended = false
      source.resume()
    }
    lock.unlock()
  }

  /// Hands over what the terminal still holds, then ends the stream.
  ///
  /// A process that exits leaves its last lines in the kernel buffer, and the read source may not
  /// have been scheduled yet on a loaded machine: closing the descriptor then would drop exactly
  /// the lines that explain a failure. They are read here, on the reader's own queue so that no
  /// event handler runs in between, and yielded before the stream finishes.
  func finish() {
    queue.sync {
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        return
      }
      lock.unlock()

      enqueue(readRemainingBytes())
      flush(endOfFile: false)

      lock.lock()
      isFinished = true
      if isSuspended {
        isSuspended = false
        source.resume()
      }
      source.cancel()
      lock.unlock()
    }
    continuation.finish()
  }

  /// Everything readable without waiting, up to the high-water mark: a grandchild still writing
  /// must not keep the session from ending.
  private func readRemainingBytes() -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
    var collected: [UInt8] = []
    while collected.count < Self.highWaterMark {
      let count = buffer.withUnsafeMutableBytes { pointer in
        read(descriptor, pointer.baseAddress, Self.readBufferSize)
      }
      if count > 0 {
        collected.append(contentsOf: buffer[0..<count])
      } else if count < 0, errno == EINTR {
        continue
      } else {
        break
      }
    }
    return collected
  }

  private func readAvailableBytes() {
    var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
    var collected: [UInt8] = []

    while true {
      let count = buffer.withUnsafeMutableBytes { pointer in
        read(descriptor, pointer.baseAddress, Self.readBufferSize)
      }

      if count > 0 {
        collected.append(contentsOf: buffer[0..<count])
        // Hand the burst over rather than reading the child dry in a single pass: the queue
        // must stay available for the flush timer and the cancel handler.
        if collected.count >= Self.highWaterMark { break }
        continue
      }

      if count == 0 {
        enqueue(collected)
        flush(endOfFile: true)
        return
      }

      switch errno {
      case EINTR:
        continue
      case EAGAIN:
        break
      default:
        // EIO is how a master reports that the last slave descriptor is gone.
        enqueue(collected)
        flush(endOfFile: true)
        return
      }
      break
    }

    enqueue(collected)
    scheduleFlush()
  }

  private func enqueue(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    pending.append(contentsOf: bytes)
    lock.unlock()
  }

  private func scheduleFlush() {
    lock.lock()
    let alreadyScheduled = isFlushScheduled || pending.isEmpty
    if !alreadyScheduled {
      isFlushScheduled = true
    }
    lock.unlock()

    guard !alreadyScheduled else { return }
    queue.asyncAfter(deadline: .now() + Self.coalescingWindow) { [weak self] in
      self?.flush(endOfFile: false)
    }
  }

  private func flush(endOfFile: Bool) {
    lock.lock()
    let bytes = pending
    pending.removeAll(keepingCapacity: true)
    isFlushScheduled = false
    let hasFinished = isFinished
    // Bytes that are never yielded are never acknowledged either, so they must not
    // raise the outstanding count.
    if !hasFinished {
      outstandingByteCount += bytes.count
    }
    // Suspending stops draining the kernel buffer, which blocks the writing process instead of
    // letting the application accumulate unbounded output in memory. It has to happen before the
    // bytes leave the lock: the consumer acknowledges them on another thread and would otherwise
    // resume a source that is not suspended yet.
    if isThrottling, !isSuspended, !hasFinished, !endOfFile,
      outstandingByteCount > Self.highWaterMark
    {
      isSuspended = true
      source.suspend()
    }
    lock.unlock()

    guard !hasFinished else { return }
    if !bytes.isEmpty {
      continuation.yield(.bytes(bytes))
    }
    if endOfFile {
      continuation.yield(.endOfFile)
    }
  }
}
