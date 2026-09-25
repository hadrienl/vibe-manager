import Foundation
import VibeApplication

/// Follows a transcript as its CLI appends to it (#38).
///
/// Whole lines only — the CLI may be in the middle of writing the last one — resumed where the
/// last reading stopped. A file that got shorter, or whose inode changed, was replaced: it is read
/// again from its start, after a `.reset`. The disk wakes the reader (a `vnode` source on the
/// file), with a slow poll underneath for what the source cannot see: a file that does not exist
/// yet, or one replaced under its name.
public struct FileTranscriptTail: TranscriptTailing {
  /// Lines handed over at once while a long transcript is first read, so that the reader can
  /// show progress rather than wait for megabytes.
  static let batchSize = 2_000

  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(1)) {
    self.pollInterval = pollInterval
  }

  public func follow(_ file: URL) -> AsyncStream<TranscriptChunk> {
    let pollInterval = pollInterval
    return AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        var reader = TranscriptLineReader(file: file)
        let wake = WakeSignal()
        var watcher: FileWatcher?
        var first = true
        while !Task.isCancelled {
          let reading = reader.readAvailable()
          if reading.wasReset { continuation.yield(.reset) }
          if reading.lines.isEmpty {
            // The first reading is always handed over, empty or not: it says the file was read.
            if first { continuation.yield(.lines([])) }
          } else {
            var start = 0
            while start < reading.lines.count {
              let end = min(start + Self.batchSize, reading.lines.count)
              continuation.yield(.lines(Array(reading.lines[start..<end])))
              start = end
            }
          }
          first = false
          if watcher?.inode != reader.inode {
            watcher = reader.inode.flatMap { _ in FileWatcher(path: file.path, wake: wake) }
          }
          await wake.wait(timeout: pollInterval)
        }
        watcher?.cancel()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func read(_ file: URL) async -> [Data] {
    await Task.detached(priority: .utility) {
      var reader = TranscriptLineReader(file: file)
      return reader.readAvailable().lines
    }.value
  }
}

/// Reads the complete lines a file gained since the last reading.
struct TranscriptLineReader {
  let file: URL
  private(set) var offset: UInt64 = 0
  private(set) var inode: UInt64?

  init(file: URL) {
    self.file = file
  }

  struct Reading {
    var lines: [Data] = []
    var wasReset = false
  }

  mutating func readAvailable() -> Reading {
    var reading = Reading()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else { return reading }
    let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if let inode, inode != identifier || size < offset {
      offset = 0
      reading.wasReset = true
    }
    inode = identifier
    guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return reading }
    defer { try? handle.close() }
    try? handle.seek(toOffset: offset)
    guard let data = try? handle.readToEnd(),
      let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
    else { return reading }
    let complete = data[data.startIndex...lastNewline]
    offset += UInt64(complete.count)
    reading.lines = complete.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    return reading
  }
}

/// Wakes a waiting reader, or lets it go after a timeout.
final class WakeSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = false
  private var waiter: CheckedContinuation<Void, Never>?

  func fire() {
    lock.lock()
    if let waiter {
      self.waiter = nil
      lock.unlock()
      waiter.resume()
    } else {
      pending = true
      lock.unlock()
    }
  }

  func wait(timeout: Duration) async {
    let timer = Task {
      try? await Task.sleep(for: timeout)
      self.fire()
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        if pending {
          pending = false
          lock.unlock()
          continuation.resume()
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
    } onCancel: {
      self.fire()
    }
    timer.cancel()
    clearPending()
  }

  private func clearPending() {
    lock.withLock { pending = false }
  }
}

/// A `vnode` source on one file: fires when it grows, is written, renamed or deleted.
final class FileWatcher: @unchecked Sendable {
  let inode: UInt64?
  private let source: DispatchSourceFileSystemObject

  init?(path: String, wake: WakeSignal) {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    var status = stat()
    inode = fstat(descriptor, &status) == 0 ? UInt64(status.st_ino) : nil
    source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.extend, .write, .delete, .rename],
      queue: DispatchQueue.global(qos: .utility))
    source.setEventHandler { wake.fire() }
    source.setCancelHandler { close(descriptor) }
    source.resume()
  }

  func cancel() {
    source.cancel()
  }

  deinit {
    source.cancel()
  }
}
