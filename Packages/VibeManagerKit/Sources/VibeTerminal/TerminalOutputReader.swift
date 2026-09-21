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

  func didConsume(byteCount: Int) {
    lock.lock()
    outstandingByteCount = max(0, outstandingByteCount - byteCount)
    let shouldResume = isSuspended && outstandingByteCount <= Self.lowWaterMark && !isFinished
    if shouldResume {
      isSuspended = false
    }
    lock.unlock()

    if shouldResume {
      source.resume()
    }
  }

  func finish() {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let wasSuspended = isSuspended
    isSuspended = false
    lock.unlock()

    // A suspended source never runs its cancel handler, and the descriptor would leak.
    if wasSuspended {
      source.resume()
    }
    source.cancel()
    continuation.finish()
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
    outstandingByteCount += bytes.count
    let shouldSuspend =
      !isSuspended && !isFinished && outstandingByteCount > Self.highWaterMark && !endOfFile
    if shouldSuspend {
      isSuspended = true
    }
    let hasFinished = isFinished
    lock.unlock()

    if !bytes.isEmpty, !hasFinished {
      continuation.yield(.bytes(bytes))
    }
    // Suspending stops draining the kernel buffer, which blocks the writing process instead of
    // letting the application accumulate unbounded output in memory.
    if shouldSuspend {
      source.suspend()
    }
    if endOfFile, !hasFinished {
      continuation.yield(.endOfFile)
    }
  }
}
