import Foundation
import VibeApplication

/// Follows a transcript as its CLI appends to it (#38).
///
/// Whole lines only — the CLI may be in the middle of writing the last one — resumed where the
/// last reading stopped, or where a reading put aside stopped (#249). A file that got shorter,
/// whose inode changed, or whose bytes before that point changed, was replaced: it is read again
/// from its start, after a `.reset`. The disk wakes the reader (a `vnode` source on the
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

  public func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<
    TranscriptChunk
  > {
    let pollInterval = pollInterval
    let chunkSize = chunkSize
    return AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        var reader = TranscriptLineReader(file: file, from: position, chunkSize: chunkSize)
        let wake = WakeSignal()
        var watcher: FileWatcher?
        var first = true
        var wasCaughtUp = false
        while !Task.isCancelled {
          let (reading, records) = Signposts.interval("transcript.chunk") {
            Self.readChunk(with: &reader)
          }
          if reading.wasReset { continuation.yield(.reset) }
          // The first reading is always handed over, empty or not: it says the file was read. So is
          // the one that reaches the end of the file, which says the reading caught up.
          let isCaughtUp = !reading.hasMore
          if !records.isEmpty || first || isCaughtUp != wasCaughtUp {
            continuation.yield(
              .records(records, through: reader.position, isCaughtUp: isCaughtUp))
          }
          first = false
          wasCaughtUp = isCaughtUp
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

  public func read(_ file: URL) async -> [TranscriptRecord] {
    let chunkSize = chunkSize
    return await Task.detached(priority: .utility) {
      var reader = TranscriptLineReader(file: file, chunkSize: chunkSize)
      var records: [TranscriptRecord] = []
      var reading: TranscriptLineReader.Reading
      repeat {
        let chunk = Self.readChunk(with: &reader)
        reading = chunk.reading
        records += chunk.records
      } while reading.hasMore
      return records
    }.value
  }

  /// The next chunk and its lines parsed. What reading and parsing leave to autorelease goes with
  /// each chunk, not at the end of the file: `JSONSerialization` leaves a lot.
  static func readChunk(with reader: inout TranscriptLineReader)
    -> (reading: TranscriptLineReader.Reading, records: [TranscriptRecord])
  {
    autoreleasepool {
      let reading = reader.readChunk()
      return (reading, parse(reading.lines))
    }
  }

  /// Lines parsed on every core, in the order they came; those that are not JSON objects are
  /// left out. The few lines a followed transcript gains at a time are parsed right here.
  static func parse(_ lines: [Data]) -> [TranscriptRecord] {
    guard lines.count > 64 else { return lines.compactMap(TranscriptRecord.init(line:)) }
    let stripes = min(lines.count, ProcessInfo.processInfo.activeProcessorCount * 4)
    var parsed = [TranscriptRecord?](repeating: nil, count: lines.count)
    parsed.withUnsafeMutableBufferPointer { buffer in
      // Each stripe writes its own indices only.
      nonisolated(unsafe) let output = buffer
      DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
        let range = (lines.count * stripe / stripes)..<(lines.count * (stripe + 1) / stripes)
        autoreleasepool {
          for index in range { output[index] = TranscriptRecord(line: lines[index]) }
        }
      }
    }
    return parsed.compactMap { $0 }
  }
}

/// Reads the complete lines a file gained since the last reading, a bounded chunk at a time (#249):
/// a transcript of a hundred megabytes is never in memory at once.
struct TranscriptLineReader {
  static let chunkSize = 4 << 20

  static let fingerprintSize = 64

  let file: URL
  private let chunkSize: Int
  /// Where the complete lines handed out end.
  private(set) var offset: UInt64 = 0
  private(set) var inode: UInt64?
  private var splitter = LineSplitter()
  /// The last bytes before `offset`.
  private var fingerprint = Data()
  /// Resumed at a position not checked against the file yet.
  private var isUnchecked = false

  /// - Parameter position: where an earlier reading of the file stopped, to go on from there —
  ///   from the start if the file is no longer the one it was in.
  init(file: URL, from position: TranscriptPosition? = nil, chunkSize: Int = Self.chunkSize) {
    self.file = file
    self.chunkSize = chunkSize
    if let position {
      inode = position.inode
      offset = position.offset
      fingerprint = position.fingerprint
      isUnchecked = true
    }
  }

  /// Where this reading stands, to resume it: nil before the file was found.
  var position: TranscriptPosition? {
    inode.map { TranscriptPosition(inode: $0, offset: offset, fingerprint: fingerprint) }
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
    if let inode,
      inode != identifier || size < offset + UInt64(splitter.carriedCount)
        || (isUnchecked && !endsWithFingerprint())
    {
      offset = 0
      fingerprint = Data()
      splitter.reset()
      reading.wasReset = true
    }
    isUnchecked = false
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
    let completeCount = data.count - splitter.carriedCount
    offset = readFrom + UInt64(data.count) - UInt64(splitter.carriedCount)
    if completeCount >= Self.fingerprintSize {
      fingerprint = Data(
        data.dropFirst(completeCount - Self.fingerprintSize).prefix(Self.fingerprintSize))
    } else if completeCount > 0 {
      fingerprint = bytes(before: offset, in: handle)
    }
    reading.hasMore = size > readFrom + UInt64(data.count)
    return reading
  }

  /// Whether the bytes before `offset` are still those the reading last saw there.
  private func endsWithFingerprint() -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? handle.close() }
    return bytes(before: offset, in: handle) == fingerprint
  }

  private func bytes(before end: UInt64, in handle: FileHandle) -> Data {
    let start = end - min(end, UInt64(Self.fingerprintSize))
    guard (try? handle.seek(toOffset: start)) != nil,
      let bytes = try? handle.read(upToCount: Int(end - start))
    else { return Data() }
    return bytes
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
