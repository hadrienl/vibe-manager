import Foundation
import VibeApplication

/// Follows a transcript as its CLI appends to it (#38).
///
/// Whole lines only — the CLI may be in the middle of writing the last one — resumed where the
/// last reading stopped, or where a reading put aside stopped (#249). A file that got shorter,
/// whose inode changed, or whose bytes before that point changed, was replaced: it is read again
/// from its start, after a `.reset`. The disk wakes the reader (a `vnode` source on the file),
/// which also sees the file replaced or deleted under its name. A poll covers what it cannot see:
/// often while the file does not exist yet, rarely once it is watched (#255).
///
/// The reading is pulled by whoever decodes it: the next chunk is read, and parsed, while the one
/// handed over is decoded — never more. A long transcript is thus never read far ahead of its
/// decoder, nor held whole in memory on its way to it.
public struct FileTranscriptTail: TranscriptTailing {
  private let pollInterval: Duration
  private let watchedInterval: Duration
  private let chunkSize: Int
  private let diagnostics: any DiagnosticLog

  /// - Parameter pollInterval: how often a file not watched — not there yet, or deleted — is
  ///   looked at again.
  /// - Parameter watchedInterval: the safety net under a file already watched (#255).
  public init(
    pollInterval: Duration = .seconds(1), watchedInterval: Duration = FileWatching.safetyNet,
    diagnostics: any DiagnosticLog = NullDiagnosticLog()
  ) {
    self.init(
      pollInterval: pollInterval, watchedInterval: watchedInterval,
      chunkSize: TranscriptLineReader.chunkSize, diagnostics: diagnostics)
  }

  /// - Parameter chunkSize: the bytes read at once — and handed over at once — while a long
  ///   transcript is first read, so that the reader shows progress rather than wait for megabytes.
  init(
    pollInterval: Duration, watchedInterval: Duration = FileWatching.safetyNet, chunkSize: Int,
    diagnostics: any DiagnosticLog = NullDiagnosticLog()
  ) {
    self.pollInterval = pollInterval
    self.watchedInterval = watchedInterval
    self.chunkSize = chunkSize
    self.diagnostics = diagnostics
  }

  public func follow(_ file: URL, from position: TranscriptPosition?) -> AsyncStream<
    TranscriptChunk
  > {
    stream(of: pulledReading(file, from: position, follows: true))
  }

  public func readChunks(_ file: URL) -> AsyncStream<TranscriptChunk> {
    stream(of: pulledReading(file, from: nil, follows: false))
  }

  /// The whole file at once: for small files and tests — a long transcript is read with
  /// `readChunks`.
  public func read(_ file: URL) async -> [TranscriptRecord] {
    var records: [TranscriptRecord] = []
    for await chunk in readChunks(file) {
      switch chunk {
      case .reset: records = []
      case .records(let chunkRecords, _, _): records += chunkRecords
      }
    }
    return records
  }

  func pulledReading(_ file: URL, from position: TranscriptPosition?, follows: Bool)
    -> PulledTranscriptReading
  {
    PulledTranscriptReading(
      reader: TranscriptLineReader(file: file, from: position, chunkSize: chunkSize),
      follows: follows, pollInterval: pollInterval, watchedInterval: watchedInterval,
      diagnostics: diagnostics)
  }

  private func stream(of reading: PulledTranscriptReading) -> AsyncStream<TranscriptChunk> {
    AsyncStream(unfolding: { await reading.next() }, onCancel: { reading.cancel() })
  }

  /// The next chunk and its lines parsed. What reading and parsing leave to autorelease goes with
  /// each chunk, not at the end of the file: `JSONSerialization` leaves a lot.
  static func readChunk(with reader: inout TranscriptLineReader)
    -> (reading: TranscriptLineReader.Reading, records: [TranscriptRecord])
  {
    autoreleasepool {
      let reading = reader.readChunk()
      let file = reader.file
      let locations = zip(reading.lines, reading.lineOffsets).map { line, offset in
        TranscriptLineLocation(file: file, offset: offset, length: line.count)
      }
      return (reading, parse(reading.lines, locations: locations))
    }
  }

  /// Lines parsed on every core, in the order they came; those that are not JSON objects are
  /// left out. The few lines a followed transcript gains at a time are parsed right here.
  static func parse(_ lines: [Data], locations: [TranscriptLineLocation] = [])
    -> [TranscriptRecord]
  {
    @Sendable func record(_ index: Int) -> TranscriptRecord? {
      TranscriptRecord(
        line: lines[index], location: index < locations.count ? locations[index] : nil)
    }
    guard lines.count > 64 else { return lines.indices.compactMap(record) }
    let stripes = min(lines.count, ProcessInfo.processInfo.activeProcessorCount * 4)
    var parsed = [TranscriptRecord?](repeating: nil, count: lines.count)
    parsed.withUnsafeMutableBufferPointer { buffer in
      // Each stripe writes its own indices only.
      nonisolated(unsafe) let output = buffer
      DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
        let range = (lines.count * stripe / stripes)..<(lines.count * (stripe + 1) / stripes)
        autoreleasepool {
          for index in range { output[index] = record(index) }
        }
      }
    }
    return parsed.compactMap { $0 }
  }
}

/// One reading of a transcript, a chunk handed over each time its consumer asks for one (#249).
///
/// The chunk after the one handed over is read ahead, off the consumer, while it decodes: one
/// chunk at most waits for it. Each step runs after the one before it — `next()` awaits the read
/// under way before it starts another — so the reader is never touched by two at once; only the
/// read ahead and the cancellation, which `cancel()` touches from anywhere, are under the lock.
final class PulledTranscriptReading: @unchecked Sendable {
  private struct Step {
    var reading: TranscriptLineReader.Reading
    var records: [TranscriptRecord]
    var position: TranscriptPosition?
  }

  private var reader: TranscriptLineReader
  private let follows: Bool
  private let pollInterval: Duration
  private let watchedInterval: Duration
  private let diagnostics: any DiagnosticLog
  private let wake = WakeSignal()
  private var watcher: FileWatcher?
  private var pending: [TranscriptChunk] = []
  private var first = true
  private var wasCaughtUp = false
  /// Nothing was at the file's path at the last reading: its source, if any, watches nothing.
  private var isMissing = false
  /// Caught up with the file: the next step waits for it to change.
  private var waitsForChange = false
  private var isFinished = false

  private let lock = NSLock()
  private var ahead: Task<Step, Never>?
  private var isCancelled = false
  private var readCount = 0

  init(
    reader: TranscriptLineReader, follows: Bool, pollInterval: Duration,
    watchedInterval: Duration = FileWatching.safetyNet, diagnostics: any DiagnosticLog
  ) {
    self.reader = reader
    self.follows = follows
    self.pollInterval = pollInterval
    self.watchedInterval = watchedInterval
    self.diagnostics = diagnostics
  }

  deinit {
    watcher?.cancel()
  }

  /// The chunks read from the file so far, the one read ahead included: for tests.
  var chunksRead: Int { lock.withLock { readCount } }

  func next() async -> TranscriptChunk? {
    while true {
      if !pending.isEmpty { return pending.removeFirst() }
      if isFinished || Task.isCancelled || lock.withLock({ isCancelled }) {
        watcher?.cancel()
        watcher = nil
        return nil
      }
      if waitsForChange {
        waitsForChange = false
        // A deleted file's source watches nothing any more: it goes, and the poll takes over
        // until the file is back (#255).
        if isMissing {
          watcher?.cancel()
          watcher = nil
        } else if watcher?.inode != reader.inode {
          watcher?.cancel()
          watcher = reader.inode.flatMap { _ in FileWatcher(path: reader.file.path, wake: wake) }
          // Read once more before waiting: what was written between the reading and the watch
          // would otherwise wait for the safety net.
          if watcher != nil { continue }
        }
        await wake.wait(timeout: watcher == nil ? pollInterval : watchedInterval)
        continue
      }
      take(await nextStep())
    }
  }

  func cancel() {
    lock.withLock {
      isCancelled = true
      ahead?.cancel()
      ahead = nil
    }
    wake.fire()
  }

  /// The chunk read ahead, or read now; the one after it is read ahead when the file holds more.
  private func nextStep() async -> Step {
    let task = lock.withLock {
      let task = ahead ?? readTask()
      ahead = nil
      return task
    }
    let step = await task.value
    if step.reading.hasMore {
      lock.withLock {
        if !isCancelled { ahead = readTask() }
      }
    }
    return step
  }

  /// Called under the lock.
  private func readTask() -> Task<Step, Never> {
    readCount += 1
    return Task.detached(priority: .utility) { self.read() }
  }

  private func read() -> Step {
    Signposts.interval("transcript.chunk") {
      let (reading, records) = FileTranscriptTail.readChunk(with: &reader)
      return Step(reading: reading, records: records, position: reader.position)
    }
  }

  private func take(_ step: Step) {
    if step.reading.skippedLines > 0 {
      // A line longer than the splitter keeps: whatever it held — a huge tool result — is not
      // shown.
      diagnostics.record(
        .session, .notice, "transcript.lineSkipped", ["lines": .count(step.reading.skippedLines)])
    }
    isMissing = step.reading.isMissing
    if step.reading.wasReset { pending.append(.reset) }
    // The first reading is always handed over, empty or not: it says the file was read. So is
    // the one that reaches the end of the file, which says the reading caught up, and the one
    // after a reset, which ends the reading again even when the file holds no line yet.
    let isCaughtUp = !step.reading.hasMore
    if !step.records.isEmpty || first || step.reading.wasReset || isCaughtUp != wasCaughtUp {
      pending.append(.records(step.records, through: step.position, isCaughtUp: isCaughtUp))
    }
    first = false
    wasCaughtUp = isCaughtUp
    guard isCaughtUp else { return }
    if follows { waitsForChange = true } else { isFinished = true }
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
  private var splitter: LineSplitter
  /// In a line too long to keep, skipped to its end.
  private var isSkipping = false
  /// The last bytes before `offset`.
  private var fingerprint = Data()
  /// Resumed at a position not checked against the file yet.
  private var isUnchecked = false

  /// - Parameter position: where an earlier reading of the file stopped, to go on from there —
  ///   from the start if the file is no longer the one it was in.
  /// - Parameter maximumLineLength: a longer line is skipped, and counted in `skippedLines`.
  init(
    file: URL, from position: TranscriptPosition? = nil, chunkSize: Int = Self.chunkSize,
    maximumLineLength: Int = LineSplitter.defaultMaximumLineLength
  ) {
    self.file = file
    self.chunkSize = chunkSize
    splitter = LineSplitter(maximumLineLength: maximumLineLength)
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
    /// Where each line starts in the file.
    var lineOffsets: [UInt64] = []
    var wasReset = false
    /// Nothing is at the file's path.
    var isMissing = false
    /// The file already holds more than this chunk: read on without waiting.
    var hasMore = false
    /// Lines found too long to keep in this chunk: left out.
    var skippedLines = 0
  }

  /// The complete lines of the next chunk: `chunkSize` bytes read at most.
  mutating func readChunk() -> Reading {
    var reading = Reading()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else {
      reading.isMissing = true
      return reading
    }
    let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if let inode,
      inode != identifier || size < offset + UInt64(splitter.pendingCount)
        || (isUnchecked && !endsWithFingerprint())
    {
      offset = 0
      fingerprint = Data()
      splitter.reset()
      isSkipping = false
      reading.wasReset = true
    }
    isUnchecked = false
    inode = identifier
    // A line cut by the end of the last chunk is carried: reading goes on after it.
    let readFrom = offset + UInt64(splitter.pendingCount)
    guard size > readFrom, let handle = try? FileHandle(forReadingFrom: file) else {
      return reading
    }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: readFrom)) != nil,
      let data = try? handle.read(upToCount: chunkSize), !data.isEmpty
    else { return reading }
    var lines: [Data] = []
    var lineOffsets: [UInt64] = []
    // The incomplete line carried starts at `offset`; the lines are located from there.
    let bufferStart = offset
    splitter.appendLocated(data) { line, start in
      lines.append(line)
      lineOffsets.append(bufferStart + UInt64(start))
    }
    reading.lines = lines
    reading.lineOffsets = lineOffsets
    // Nothing carried after a chunk that does not end a line: the splitter gave the line up.
    let skips = data.last != 0x0A && splitter.pendingCount == 0
    if skips, !isSkipping { reading.skippedLines += 1 }
    isSkipping = skips
    let completeCount = data.count - splitter.pendingCount
    offset = readFrom + UInt64(data.count) - UInt64(splitter.pendingCount)
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
}
