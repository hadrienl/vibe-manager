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
  private let pollInterval: Duration
  private let chunkSize: Int

  public init(pollInterval: Duration = .seconds(1)) {
    self.init(pollInterval: pollInterval, chunkSize: TranscriptLineReader.chunkSize)
  }

  /// - Parameter chunkSize: the bytes read at once — and handed over at once — while a long
  ///   transcript is first read, so that the reader shows progress rather than wait for megabytes.
  init(pollInterval: Duration, chunkSize: Int) {
    self.pollInterval = pollInterval
    self.chunkSize = chunkSize
  }

  public func follow(_ file: URL) -> AsyncStream<TranscriptChunk> {
    let pollInterval = pollInterval
    let chunkSize = chunkSize
    return AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        var reader = TranscriptLineReader(file: file, chunkSize: chunkSize)
        let wake = WakeSignal()
        var watcher: FileWatcher?
        var first = true
        while !Task.isCancelled {
          // What reading leaves to autorelease goes with each chunk, not at the end of the file.
          let reading = autoreleasepool { reader.readChunk() }
          if reading.wasReset { continuation.yield(.reset) }
          // The first reading is always handed over, empty or not: it says the file was read.
          if !reading.lines.isEmpty || first { continuation.yield(.lines(reading.lines)) }
          first = false
          if reading.hasMore { continue }
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

/// Reads the complete lines a file gained since the last reading, a bounded chunk at a time (#249):
/// a transcript of a hundred megabytes is never in memory at once.
struct TranscriptLineReader {
  static let chunkSize = 4 << 20

  let file: URL
  private let chunkSize: Int
  /// Where the complete lines handed out end.
  private(set) var offset: UInt64 = 0
  private(set) var inode: UInt64?
  private var splitter = LineSplitter()

  init(file: URL, chunkSize: Int = Self.chunkSize) {
    self.file = file
    self.chunkSize = chunkSize
  }

  struct Reading {
    var lines: [Data] = []
    var wasReset = false
    /// The file already holds more than this chunk: read on without waiting.
    var hasMore = false
  }

  /// The complete lines of the next chunk: `chunkSize` bytes read at most.
  mutating func readChunk() -> Reading {
    var reading = Reading()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else { return reading }
    let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if let inode, inode != identifier || size < offset + UInt64(splitter.carriedCount) {
      offset = 0
      splitter.reset()
      reading.wasReset = true
    }
    inode = identifier
    // A line cut by the end of the last chunk is carried: reading goes on after it.
    let readFrom = offset + UInt64(splitter.carriedCount)
    guard size > readFrom, let handle = try? FileHandle(forReadingFrom: file) else {
      return reading
    }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: readFrom)) != nil,
      let data = try? handle.read(upToCount: chunkSize), !data.isEmpty
    else { return reading }
    reading.lines = splitter.lines(in: data)
    offset = readFrom + UInt64(data.count) - UInt64(splitter.carriedCount)
    reading.hasMore = size > readFrom + UInt64(data.count)
    return reading
  }

  /// Every complete line up to the end of the file, chunk after chunk.
  mutating func readAvailable() -> Reading {
    var reading = Reading()
    repeat {
      let chunk = readChunk()
      if chunk.wasReset {
        reading.lines = []
        reading.wasReset = true
      }
      reading.lines += chunk.lines
      reading.hasMore = chunk.hasMore
    } while reading.hasMore
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
    // A timer cancelled because the disk woke the reader first must not fire as well: it would
    // leave a wake pending, the next wait would return at once, and the reader would spin.
    let timer = Task {
      do {
        try await Task.sleep(for: timeout)
        self.fire()
      } catch {}
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
