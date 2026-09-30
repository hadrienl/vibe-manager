import Foundation
import VibeApplication

/// Follows the lines appended to one file, woken by the file's own `vnode` events: an idle file
/// costs a descriptor and nothing else, and a line is handed out as soon as it is written.
///
/// The file may not exist yet — a Claude Code transcript is only written at the first exchange —
/// in which case its folder is watched until it appears. A file cut short or replaced (another
/// inode) is read again from its beginning. Reading goes by blocks of `blockSize`, so that a long
/// catch-up, after the Mac slept, never holds more than a block and the incomplete line.
/// Follows a file an agent appends to, line by line: only whole lines, from where the reading
/// started, and from the beginning again when the file was replaced or cut short. It wakes when the
/// file, or the folder it will appear in, changes, never on a clock but for a long safety net.
struct AppendedLines: Sendable {
  enum Start: Sendable {
    /// What the file holds already belongs to the past.
    case end
    case beginning
    /// From this offset, what was before having been read otherwise.
    case offset(UInt64)
  }

  /// What a `vnode` source was just armed on.
  enum Watching: Sendable {
    case file
    case folder
  }

  static let blockSize = 1024 * 1024

  let file: URL
  let start: Start
  /// When not empty, only the lines that hold one of these bytes are handed out: the others are
  /// never decoded by the readers, who look for these very words first.
  var needles: [Data] = []
  /// The wait under a watched file or folder, should an event be lost.
  var safetyNet: Duration = FileWatching.safetyNet
  /// Only while neither the file nor its folder can be watched: the first pace for 30 s, then
  /// twice as slow for every further 30 s, up to the upper bound.
  var absentRetry: ClosedRange<Duration> = .milliseconds(500)...(.seconds(30))
  /// Told each time a `vnode` source is armed — what a test waits for before writing.
  var onWatching: (@Sendable (Watching) -> Void)?

  init(file: URL, start: Start, needles: [Data] = []) {
    self.file = file
    self.start = start
    self.needles = needles
  }

  func lines() -> AsyncStream<Data> {
    let follower = self
    return AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        await follower.follow { continuation.yield($0) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func follow(_ yield: (Data) -> Void) async {
    let wake = WakeSignal()
    var watcher: FileWatcher?
    var watching: Watching?
    var splitter = LineSplitter()
    var inode: UInt64?
    var offset: UInt64
    switch start {
    case .end: offset = Self.size(of: file) ?? 0
    case .beginning: offset = 0
    case .offset(let value): offset = value
    }
    var absentSince: ContinuousClock.Instant?
    var folder: String?

    while !Task.isCancelled {
      let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else {
        // Watches the nearest folder that exists: the file's own, or an ancestor until the missing
        // folders appear. Armed again whenever that folder changes or is replaced, then `open` is
        // tried once more, for a file created before the source was armed would send no event.
        if let nearest = Self.nearestFolder(above: file),
          watching != .folder || folder != nearest.path
            || (watcher?.inode != nil && watcher?.inode != nearest.inode)
        {
          watcher = FileWatcher(path: nearest.path, wake: wake)
          watching = watcher == nil ? nil : .folder
          folder = watching == .folder ? nearest.path : nil
          if watching == .folder {
            onWatching?(.folder)
            continue
          }
        }
        if watching == .folder {
          await wake.wait(timeout: safetyNet)
        } else {
          let since = absentSince ?? .now
          absentSince = since
          try? await Task.sleep(for: absentInterval(after: .now - since))
        }
        continue
      }
      absentSince = nil
      var status = stat()
      guard fstat(descriptor, &status) == 0 else {
        close(descriptor)
        continue
      }
      let identifier = UInt64(status.st_ino)
      let size = UInt64(max(status.st_size, 0))
      if let inode, inode != identifier || size < offset {
        offset = 0
        splitter.reset()
      } else if inode == nil, size < offset {
        offset = 0
      }
      inode = identifier
      // Armed before the size is taken: whatever is written while the file is read wakes the next
      // wait. A source just armed makes the file be looked at once more, for what was written
      // between `fstat` and the arming — the line of a file created empty, then written — would
      // send no event and wait for the safety net.
      if watching != .file || watcher?.inode != identifier {
        watcher = FileWatcher(path: file.path, wake: wake)
        watching = watcher == nil ? nil : .file
        folder = nil
        if watching == .file {
          onWatching?(.file)
          close(descriptor)
          continue
        }
      }

      var read = 0
      var handed = 0
      while offset < size, !Task.isCancelled {
        var block = Data(count: Int(min(UInt64(Self.blockSize), size - offset)))
        let count = block.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress, $0.count, off_t(offset))
        }
        guard count > 0 else { break }
        if count < block.count { block.removeSubrange(count...) }
        offset += UInt64(count)
        read += count
        splitter.append(block) { line in
          guard needles.isEmpty || LineSplitter.contains(line, anyOf: needles) else { return }
          handed += 1
          yield(line)
        }
      }
      close(descriptor)
      Signposts.signposter.emitEvent("agents.appendedLines", "\(read) bytes, \(handed) lines")

      if watching == .file {
        await wake.wait(timeout: safetyNet)
      } else {
        try? await Task.sleep(for: absentRetry.lowerBound)
      }
    }
    watcher?.cancel()
  }

  func absentInterval(after elapsed: Duration) -> Duration {
    let period = Duration.seconds(30)
    guard elapsed >= period else { return absentRetry.lowerBound }
    let periods = min(Int(elapsed / period), 16)
    return min(absentRetry.lowerBound * (1 << periods), absentRetry.upperBound)
  }

  /// The closest folder above `file` that exists, with its inode.
  static func nearestFolder(above file: URL) -> (path: String, inode: UInt64)? {
    var folder = file.deletingLastPathComponent()
    while true {
      var status = stat()
      if stat(folder.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
        return (folder.path, UInt64(status.st_ino))
      }
      let parent = folder.deletingLastPathComponent()
      guard parent.path != folder.path, !folder.path.isEmpty, folder.path != "/" else { return nil }
      folder = parent
    }
  }

  static func size(of url: URL) -> UInt64? {
    var status = stat()
    guard stat(url.path, &status) == 0 else { return nil }
    return UInt64(max(status.st_size, 0))
  }
}
