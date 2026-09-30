import Foundation
import VibeApplication

/// Follows a transcript as its CLI appends to it (#38).
///
/// Whole lines only — the CLI may be in the middle of writing the last one — resumed where the
/// last reading stopped. A file that got shorter, or whose inode changed, was replaced: it is read
/// again from its start, after a `.reset`. The disk wakes the reader (a `vnode` source on the
/// file), which also sees the file replaced or deleted under its name. A poll covers what it
/// cannot see: often while the file does not exist yet, rarely once it is watched (#255).
public struct FileTranscriptTail: TranscriptTailing {
  /// Lines handed over at once while a long transcript is first read, so that the reader can
  /// show progress rather than wait for megabytes.
  static let batchSize = 2_000

  private let pollInterval: Duration
  private let watchedInterval: Duration

  public init(
    pollInterval: Duration = .seconds(1),
    watchedInterval: Duration = FileWatching.safetyNet
  ) {
    self.pollInterval = pollInterval
    self.watchedInterval = watchedInterval
  }

  public func follow(_ file: URL) -> AsyncStream<TranscriptChunk> {
    let pollInterval = pollInterval
    let watchedInterval = watchedInterval
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
          // A deleted file's source watches nothing any more: it goes, and the poll takes over
          // until the file is back.
          if reading.isMissing {
            watcher?.cancel()
            watcher = nil
          } else if watcher?.inode != reader.inode {
            watcher?.cancel()
            watcher = reader.inode.flatMap { _ in FileWatcher(path: file.path, wake: wake) }
            // Read once more before waiting: what was written between the reading and the watch
            // would otherwise wait for the safety net.
            if watcher != nil { continue }
          }
          await wake.wait(timeout: watcher == nil ? pollInterval : watchedInterval)
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
    /// Nothing is at the file's path.
    var isMissing = false
  }

  mutating func readAvailable() -> Reading {
    var reading = Reading()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else {
      reading.isMissing = true
      return reading
    }
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
