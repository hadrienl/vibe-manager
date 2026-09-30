import Foundation
import Testing

@testable import VibeAgents

/// Records the `vnode` sources a follower arms, so that a test writes only once one is armed.
final class WatchLog: @unchecked Sendable {
  private let lock = NSLock()
  private var armed: [AppendedLines.Watching] = []
  private var waiters: [(AppendedLines.Watching, Int, CheckedContinuation<Void, Never>)] = []

  func record(_ watching: AppendedLines.Watching) {
    lock.lock()
    armed.append(watching)
    let count = armed.filter { $0 == watching }.count
    let ready = waiters.filter { $0.0 == watching && $0.1 <= count }
    waiters.removeAll { $0.0 == watching && $0.1 <= count }
    lock.unlock()
    for waiter in ready { waiter.2.resume() }
  }

  /// Returns once `count` sources were armed on `watching` since the follower started.
  func wait(for watching: AppendedLines.Watching, count: Int = 1) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if armed.filter({ $0 == watching }).count >= count {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((watching, count, continuation))
        lock.unlock()
      }
    }
  }
}

private func lines(_ text: String) -> [String] {
  var splitter = LineSplitter()
  var found: [String] = []
  splitter.append(Data(text.utf8)) { found.append(String(decoding: $0, as: UTF8.self)) }
  return found
}

@Suite("Line splitter")
struct LineSplitterTests {
  @Test("Whole lines are handed out, the incomplete rest waits for the next block")
  func wholeLinesAndRest() {
    var splitter = LineSplitter()
    var found: [String] = []
    splitter.append(Data("a\nbb\nc".utf8)) { found.append(String(decoding: $0, as: UTF8.self)) }
    #expect(found == ["a", "bb"])
    #expect(splitter.pendingCount == 1)
    splitter.append(Data("c\nd".utf8)) { found.append(String(decoding: $0, as: UTF8.self)) }
    #expect(found == ["a", "bb", "cc"])
    #expect(splitter.pendingCount == 1)
  }

  @Test("Empty lines count, a final newline leaves nothing pending")
  func emptyLines() {
    #expect(lines("\n\nx\n") == ["", "", "x"])
    #expect(lines("no newline").isEmpty)
  }

  @Test("A line cut across many blocks comes out whole, each byte copied at most twice")
  func lineAcrossBlocks() {
    var splitter = LineSplitter()
    var found: [String] = []
    for piece in ["ab", "cd", "ef", "gh\nij"] {
      splitter.append(Data(piece.utf8)) { found.append(String(decoding: $0, as: UTF8.self)) }
    }
    #expect(found == ["abcdefgh"])
    #expect(splitter.copiedBytes <= 2 * 11)
  }

  @Test("Slices that do not start at 0 decode as JSON")
  func slicesDecode() throws {
    var splitter = LineSplitter()
    var decoded: [Int] = []
    var starts: [Int] = []
    splitter.append(Data("{\"n\":1}\n{\"n\":2}\n".utf8)) { line in
      starts.append(line.startIndex)
      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Int]
      decoded.append(object?["n"] ?? 0)
    }
    #expect(decoded == [1, 2])
    #expect(starts.contains { $0 != 0 })
  }

  @Test("A line longer than the limit is dropped whole, the next ones still come")
  func runawayLine() {
    var splitter = LineSplitter(maximumLineLength: 8)
    var found: [String] = []
    for piece in ["0123456789", "abcdef", "ghi\nnext\n"] {
      splitter.append(Data(piece.utf8)) { found.append(String(decoding: $0, as: UTF8.self)) }
    }
    #expect(found == ["next"])
    #expect(splitter.pendingCount == 0)
  }

  @Test("Ten megabytes of short lines: every line, and a copy no larger than twice the input")
  func linearWork() {
    let line = Data((String(repeating: "x", count: 399) + "\n").utf8)
    var file = Data()
    for _ in 0..<(10 * 1024 * 1024 / line.count) { file.append(line) }
    var splitter = LineSplitter()
    var count = 0
    var start = file.startIndex
    while start < file.endIndex {
      // Blocks that end in the middle of a line, as a read by blocks does.
      let end = min(start + AppendedLines.blockSize + 7, file.endIndex)
      splitter.append(file[start..<end]) { _ in count += 1 }
      start = end
    }
    #expect(count == file.count / line.count)
    #expect(splitter.copiedBytes <= 2 * file.count)
  }

  @Test("Needles are found anywhere in a line, and only there")
  func needles() {
    let line = Data("{\"type\":\"response_item\",\"name\":\"request_user_input\"}".utf8)
    #expect(LineSplitter.contains(line, anyOf: [Data("request_user_input".utf8)]))
    #expect(LineSplitter.contains(line, anyOf: [Data("nothing".utf8), Data("type".utf8)]))
    #expect(!LineSplitter.contains(line, anyOf: [Data("function_call_output".utf8)]))
    #expect(!LineSplitter.contains(Data(), anyOf: [Data("x".utf8)]))
  }
}

@Suite("Appended lines")
struct AppendedLinesTests {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppendedLines-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }

  /// Collects what a follower hands out, as it comes.
  final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var waiter: (Int, CheckedContinuation<Void, Never>)?
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Data>) {
      task = Task { [weak self] in
        for await line in stream { self?.add(String(decoding: line, as: UTF8.self)) }
      }
    }

    deinit { task?.cancel() }

    private func add(_ line: String) {
      lock.lock()
      lines.append(line)
      let ready = waiter.flatMap { $0.0 <= lines.count ? $0.1 : nil }
      if ready != nil { waiter = nil }
      lock.unlock()
      ready?.resume()
    }

    private func release() {
      lock.lock()
      let pending = waiter?.1
      waiter = nil
      lock.unlock()
      pending?.resume()
    }

    /// Every line received, once there are `count`, or what came before a long guard — which fails
    /// the test, but never serves as its clock.
    func first(_ count: Int) async -> [String] {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
              self.lock.lock()
              if self.lines.count >= count {
                self.lock.unlock()
                continuation.resume()
              } else {
                self.waiter = (count, continuation)
                self.lock.unlock()
              }
            }
          } onCancel: {
            self.release()
          }
        }
        group.addTask { try? await Task.sleep(for: .seconds(10)) }
        await group.next()
        group.cancelAll()
      }
      return lock.withLock { lines }
    }
  }

  @Test("Lines written after the start are handed out, those already there are not")
  func fromTheEnd() async throws {
    let url = try folder().appendingPathComponent("t.jsonl")
    try Data("old\n".utf8).write(to: url)
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .end)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .file)

    try append("new\nhalf", to: url)
    #expect(await received.first(1) == ["new"])
    try append(" and done\n", to: url)
    #expect(await received.first(2) == ["new", "half and done"])
  }

  @Test("A file created after the start is followed from its first line")
  func fileCreatedLater() async throws {
    let url = try folder().appendingPathComponent("t.jsonl")
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .end)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .folder)

    try Data("first\n".utf8).write(to: url)
    #expect(await received.first(1) == ["first"])
    await log.wait(for: .file)
    try append("second\n", to: url)
    #expect(await received.first(2) == ["first", "second"])
  }

  @Test("A file whose folders do not exist yet is seen as soon as they and it appear")
  func foldersCreatedLater() async throws {
    let root = try folder()
    let outer = root.appendingPathComponent("project")
    let inner = outer.appendingPathComponent("session")
    let url = inner.appendingPathComponent("t.jsonl")
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .end)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .folder)

    // Each folder that appears is watched in turn, well before the safety net would look.
    try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: false)
    await log.wait(for: .folder, count: 2)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
    await log.wait(for: .folder, count: 3)
    try Data("first\n".utf8).write(to: url)
    #expect(await received.first(1) == ["first"])
  }

  @Test("A file created empty in a watched folder, then written, hands its line out at once")
  func createdThenWritten() async throws {
    // `Data.write` creates the file, then writes it: the folder's event may wake the follower in
    // between, when the file is still empty. Its line must not wait for the safety net — about one
    // time in four it did, before the file was looked at again once its own source was armed.
    for attempt in 0..<100 {
      let directory = try folder()
      let url = directory.appendingPathComponent("t.jsonl")
      let log = WatchLog()
      var appended = AppendedLines(file: url, start: .end)
      appended.safetyNet = .seconds(3600)
      appended.onWatching = { log.record($0) }
      let received = Received(appended.lines())
      await log.wait(for: .folder)
      try Data("line \(attempt)\n".utf8).write(to: url)
      let first = await received.first(1)
      #expect(first == ["line \(attempt)"])
      if first != ["line \(attempt)"] { return }
    }
  }

  @Test("A folder removed and made again is watched again")
  func folderMadeAgain() async throws {
    let directory = try folder().appendingPathComponent("session")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let url = directory.appendingPathComponent("t.jsonl")
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .end)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .folder)

    try FileManager.default.removeItem(at: directory)
    await log.wait(for: .folder, count: 2)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    await log.wait(for: .folder, count: 3)
    try Data("again\n".utf8).write(to: url)
    #expect(await received.first(1) == ["again"])
  }

  @Test("The nearest folder is the file's own, or the closest one above that exists")
  func nearestFolder() throws {
    let root = try folder()
    let own = AppendedLines.nearestFolder(above: root.appendingPathComponent("t.jsonl"))
    #expect(own?.path == root.path)
    let above = AppendedLines.nearestFolder(
      above: root.appendingPathComponent("a/b/t.jsonl"))
    #expect(above?.path == root.path)
  }

  @Test("A file replaced by another is read again from its beginning")
  func replacedFile() async throws {
    let directory = try folder()
    let url = directory.appendingPathComponent("t.jsonl")
    try Data("one\n".utf8).write(to: url)
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .beginning)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    #expect(await received.first(1) == ["one"])
    await log.wait(for: .file)

    let replacement = directory.appendingPathComponent("replacement")
    try Data("fresh\n".utf8).write(to: replacement)
    #expect(rename(replacement.path, url.path) == 0)
    #expect(await received.first(2) == ["one", "fresh"])
  }

  @Test("A file cut short is read again from its beginning")
  func truncatedFile() async throws {
    let url = try folder().appendingPathComponent("t.jsonl")
    try Data("a long first line\n".utf8).write(to: url)
    let log = WatchLog()
    var appended = AppendedLines(file: url, start: .end)
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .file)

    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("short\n".utf8))
    try handle.close()
    #expect(await received.first(1) == ["short"])
  }

  @Test("With needles, only the lines that hold one are handed out")
  func needles() async throws {
    let url = try folder().appendingPathComponent("t.jsonl")
    try Data().write(to: url)
    let log = WatchLog()
    var appended = AppendedLines(
      file: url, start: .end, needles: [Data("wanted".utf8), Data("also".utf8)])
    appended.onWatching = { log.record($0) }
    let received = Received(appended.lines())
    await log.wait(for: .file)

    try append("noise\nwanted 1\nmore noise\nalso 2\n", to: url)
    #expect(await received.first(2) == ["wanted 1", "also 2"])
  }

  @Test("Without a timeout, a wait ends only when fired")
  func waitWithoutTimeout() async {
    let wake = WakeSignal()
    let waiting = Task { await wake.wait(timeout: nil) }
    wake.fire()
    await waiting.value
  }
}
