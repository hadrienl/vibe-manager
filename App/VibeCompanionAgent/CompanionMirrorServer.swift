import CompanionCore
import Foundation
import IrohLib
import VibeDevices

/// The Mac's end of the simulator mirror. Each stream is a request of `CompanionMirror`;
/// `open` runs the device's bridge, in the application's `Contents/MacOS`, for as long as the
/// stream lasts.
enum CompanionMirrorServer {
  static func serve(_ connection: Connection) async {
    do {
      while true {
        let stream = try await connection.acceptBi()
        Task.detached { await handle(stream) }
      }
    } catch {
      CompanionIroh.logger.notice(
        "mirror: gone: \(CompanionIroh.describe(error), privacy: .public)")
    }
  }

  private static func readLine(_ receiving: RecvStream) async throws -> String {
    let length = try await receiving.readExact(size: 1)[0]
    let bytes = length == 0 ? Data() : try await receiving.readExact(size: UInt32(length))
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func handle(_ stream: BiStream) async {
    let receiving = stream.recv()
    let sending = stream.send()
    guard let request = try? await readLine(receiving) else { return }
    if request == "list" {
      let devices = await DeviceCatalog.running().map {
        CompanionMirror.Device(id: $0.id, name: $0.name)
      }
      let body = (try? JSONEncoder().encode(devices)) ?? Data("[]".utf8)
      let length = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
      try? await sending.writeAll(buf: length + body)
      try? await sending.finish()
    } else if request.hasPrefix("open ") {
      await mirror(udid: String(request.dropFirst(5)), receiving, sending)
    }
  }

  private static func mirror(udid: String, _ receiving: RecvStream, _ sending: SendStream) async {
    // Bundle: Contents/Helpers/Vibe Manager Companion.app, the bridges in Contents/MacOS.
    let folder = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("MacOS")
    let bridge: DeviceBridge
    do {
      bridge = try DeviceBridge(device: udid, bridgesIn: folder)
    } catch {
      CompanionIroh.logger.error(
        "mirror: no bridge in \(folder.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      try? await sending.finish()
      return
    }
    CompanionIroh.logger.notice("mirror: \(udid, privacy: .public) opened")
    let outbox = Outbox { bridge.send("k\n") }
    Thread.detachNewThread {
      while let frame = bridge.nextFrame(), let isKey = frame.first {
        let length = withUnsafeBytes(of: UInt32(frame.count).bigEndian) { Data($0) }
        outbox.add(length + frame, isKey: isKey != 0)
      }
      outbox.finish()
    }
    let touches = Task.detached {
      while let line = try? await readLine(receiving) {
        bridge.send(line + "\n")
      }
      // The phone went: the bridge goes, and the frames with it.
      bridge.stop()
    }
    while let frame = await outbox.next() {
      do {
        try await sending.writeAll(buf: frame)
      } catch {
        break
      }
    }
    bridge.stop()
    try? await sending.finish()
    touches.cancel()
    CompanionIroh.logger.notice("mirror: \(udid, privacy: .public) closed")
  }

  /// The frames on their way to the network, between the bridge's thread and the stream's writer.
  private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var backlog = CompanionMirror.Backlog()
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false
    private let askKey: @Sendable () -> Void

    init(askKey: @escaping @Sendable () -> Void) {
      self.askKey = askKey
    }

    func add(_ frame: Data, isKey: Bool) {
      let (needsKey, resume): (Bool, (CheckedContinuation<Data?, Never>, Data)?) = lock.withLock {
        // Through the backlog even with a writer waiting: it knows when a key frame is due.
        let needsKey = backlog.add(frame, isKey: isKey)
        guard let waiter, let next = backlog.next() else { return (needsKey, nil) }
        self.waiter = nil
        return (needsKey, (waiter, next))
      }
      if needsKey { askKey() }
      if let resume { resume.0.resume(returning: resume.1) }
    }

    func finish() {
      let waiter = lock.withLock {
        finished = true
        defer { self.waiter = nil }
        return self.waiter
      }
      waiter?.resume(returning: nil)
    }

    func next() async -> Data? {
      await withCheckedContinuation { continuation in
        let ready: Data?? = lock.withLock {
          if let frame = backlog.next() { return .some(frame) }
          if finished { return .some(nil) }
          waiter = continuation
          return nil
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }
  }
}
