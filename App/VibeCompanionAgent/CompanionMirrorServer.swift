import CompanionCore
import Foundation
import IrohLib

/// The Mac's end of the simulator mirror. Each stream is a request of `CompanionMirror`;
/// `open` runs `sim-bridge`, next to the application's executable, for as long as the stream lasts.
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
      let body = (try? JSONEncoder().encode(bootedDevices())) ?? Data("[]".utf8)
      let length = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
      try? await sending.writeAll(buf: length + body)
      try? await sending.finish()
    } else if request.hasPrefix("open ") {
      await mirror(udid: String(request.dropFirst(5)), receiving, sending)
    }
  }

  private static func mirror(udid: String, _ receiving: RecvStream, _ sending: SendStream) async {
    // Bundle: Contents/Helpers/Vibe Manager Companion.app, the bridge in Contents/MacOS.
    let bridge = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("MacOS/sim-bridge")
    // A touch written to a bridge that just died must not end the agent.
    signal(SIGPIPE, SIG_IGN)
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    if udid.hasPrefix("android-") {
      process.executableURL = bridge.deletingLastPathComponent().appendingPathComponent("emu-bridge")
      process.arguments = [String(udid.dropFirst("android-".count))]
      if let token = runningEmulators().first(where: { $0.id == udid })?.token {
        process.environment = ["EMU_TOKEN": token]
      }
    } else {
      process.executableURL = bridge
      process.arguments = [udid]
    }
    process.standardInput = input
    process.standardOutput = output
    do {
      try process.run()
    } catch {
      CompanionIroh.logger.error(
        "mirror: no bridge at \(bridge.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      try? await sending.finish()
      return
    }
    CompanionIroh.logger.notice("mirror: \(udid, privacy: .public) opened")
    let toBridge = input.fileHandleForWriting
    let outbox = Outbox { try? toBridge.write(contentsOf: Data("k\n".utf8)) }
    let reading = output.fileHandleForReading
    Thread.detachNewThread {
      while let header = exactly(4, from: reading) {
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard let payload = exactly(length, from: reading), let isKey = payload.first else { break }
        outbox.add(header + payload, isKey: isKey != 0)
      }
      outbox.finish()
    }
    let touches = Task.detached {
      while let line = try? await readLine(receiving) {
        try? toBridge.write(contentsOf: Data((line + "\n").utf8))
      }
      // The phone went: the bridge goes, and the frames with it.
      try? toBridge.close()
      if process.isRunning { process.terminate() }
    }
    while let frame = await outbox.next() {
      do {
        try await sending.writeAll(buf: frame)
      } catch {
        break
      }
    }
    if process.isRunning { process.terminate() }
    try? await sending.finish()
    touches.cancel()
    CompanionIroh.logger.notice("mirror: \(udid, privacy: .public) closed")
  }

  private static func exactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data(capacity: count)
    while data.count < count {
      guard let part = try? handle.read(upToCount: count - data.count), !part.isEmpty else {
        return nil
      }
      data.append(part)
    }
    return data
  }

  /// The Android emulators running now, as the emulator itself lists them. Their id is
  /// `android-<gRPC port>`.
  private static func runningEmulators() -> [(id: String, name: String, token: String?)] {
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { file in
      let stem = file.deletingPathExtension().lastPathComponent
      guard stem.hasPrefix("pid_"), let pid = Int32(stem.dropFirst(4)), kill(pid, 0) == 0,
        let text = try? String(contentsOf: file, encoding: .utf8)
      else { return nil }
      var values: [String: String] = [:]
      for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
      }
      guard let port = values["grpc.port"] else { return nil }
      return ("android-\(port)", values["avd.name"] ?? "Android", values["grpc.token"])
    }
  }

  private static func bootedDevices() -> [CompanionMirror.Device] {
    simulators() + runningEmulators().map { CompanionMirror.Device(id: $0.id, name: $0.name) }
  }

  private static func simulators() -> [CompanionMirror.Device] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "devices", "booted", "-j"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let runtimes = root["devices"] as? [String: [[String: Any]]]
    else { return [] }
    return runtimes.values.flatMap { $0 }.compactMap { device in
      guard let id = device["udid"] as? String, let name = device["name"] as? String else {
        return nil
      }
      return CompanionMirror.Device(id: id, name: name)
    }
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
