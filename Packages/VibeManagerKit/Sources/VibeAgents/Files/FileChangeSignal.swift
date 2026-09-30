import Foundation

/// How files followed on `vnode` events are looked at again when no event came.
public enum FileWatching {
  /// The safety net under a file already watched: events carry every change on a local disk, so
  /// this only catches the rare one lost. Shared by every follower of a watched file.
  public static let safetyNet: Duration = .seconds(30)
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

  /// Returns at the next `fire()`, or once `timeout` has passed; without a timeout, no timer runs
  /// at all and only a fire — or cancellation — ends the wait.
  func wait(timeout: Duration?) async {
    // A timer cancelled because the disk woke the reader first must not fire as well: it would
    // leave a wake pending, the next wait would return at once, and the reader would spin.
    let timer = timeout.map { timeout in
      Task {
        do {
          try await Task.sleep(for: timeout)
          self.fire()
        } catch {}
      }
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
    timer?.cancel()
    clearPending()
  }

  private func clearPending() {
    lock.withLock { pending = false }
  }
}

/// A `vnode` source on one file: fires when it grows, is written, renamed or deleted. On a folder,
/// it fires when an entry is added, removed or renamed in it.
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
