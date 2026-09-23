import CoreServices
import Foundation
import VibeApplication

/// Watches folders with FSEvents, file by file, and says only that something moved.
///
/// FSEvents needs no descriptor per file — unlike `kqueue`, which would hold one open for every
/// file of a repository — and groups what happens within its latency into one callback. The
/// stream stops when nobody iterates it any more.
public struct FSEventsFileChangeObserver: FileChangeObserving {
  private let latency: TimeInterval

  public init(latency: TimeInterval = 0.3) {
    self.latency = latency
  }

  public func signals(for paths: [String]) -> AsyncStream<FileChangeSignal> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: FileChangeSignal.self, bufferingPolicy: .unbounded)
    let watch = FSEventsWatch(paths: paths, latency: latency, continuation: continuation)
    continuation.onTermination = { _ in watch.stop() }
    watch.start()
    return stream
  }
}

/// One FSEvents stream, owned by the `AsyncStream` it feeds.
///
/// Its state is only touched on its own serial queue, which FSEvents also delivers on.
private final class FSEventsWatch: @unchecked Sendable {
  private let paths: [String]
  private let latency: TimeInterval
  private let continuation: AsyncStream<FileChangeSignal>.Continuation
  private let queue = DispatchQueue(label: "com.hadrienl.VibeManager.fsevents", qos: .utility)
  private var stream: FSEventStreamRef?

  init(
    paths: [String], latency: TimeInterval,
    continuation: AsyncStream<FileChangeSignal>.Continuation
  ) {
    self.paths = paths
    self.latency = latency
    self.continuation = continuation
  }

  func start() {
    queue.async { self.open() }
  }

  func stop() {
    queue.async { self.close() }
  }

  private func open() {
    guard stream == nil, !paths.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault,
        fsEventsCallback,
        &context,
        paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags
      )
    else {
      continuation.finish()
      return
    }
    // Kept alive by the stream until it is closed: the callback's `info` is this object.
    _ = Unmanaged.passRetained(self)
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  private func close() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    Unmanaged.passUnretained(self).release()
  }

  fileprivate func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
    var changed: [String] = []
    var rescan = false
    for (path, flag) in zip(paths, flags) {
      if flag
        & FSEventStreamEventFlags(
          kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped) != 0
      {
        rescan = true
      }
      if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
        continuation.yield(.rootChanged(Self.trimmed(path)))
        continue
      }
      changed.append(Self.trimmed(path))
    }
    if rescan { continuation.yield(.mustRescan) }
    if !changed.isEmpty { continuation.yield(.changed(changed)) }
  }

  private static func trimmed(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}

private func fsEventsCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ identifiers: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watch = Unmanaged<FSEventsWatch>.fromOpaque(info).takeUnretainedValue()
  let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
  let names = (array as? [String]) ?? []
  let values = Array(UnsafeBufferPointer(start: flags, count: count))
  watch.deliver(paths: names, flags: values)
}
