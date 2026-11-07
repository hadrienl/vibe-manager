import Foundation
import VibeProcess

/// The bridge to one device (#480): `sim-bridge` for a simulator, `emu-bridge` for an emulator,
/// next to the executable. It writes the screen as H.264 frames, each a `u32` big-endian length
/// then the frame, and reads touches (`d|m|u x y`) and key frame requests (`k`), a line each.
public final class DeviceBridge: Sendable {
  private let process: StreamingProcess

  /// - Parameter folder: where the bridges are, the application's `Contents/MacOS`.
  public init(device id: String, bridgesIn folder: URL) throws {
    var environment = DeviceCatalog.environment
    let executable: String
    let argument: String
    if id.hasPrefix(DeviceCatalog.androidPrefix) {
      executable = "emu-bridge"
      argument = String(id.dropFirst(DeviceCatalog.androidPrefix.count))
      if let token = DeviceCatalog.emulators().first(where: { $0.device.id == id })?.device.token {
        environment["EMU_TOKEN"] = token
      }
    } else {
      executable = "sim-bridge"
      argument = id
    }
    process = try StreamingProcess(
      executablePath: folder.appendingPathComponent(executable).path, arguments: [argument],
      environment: environment)
  }

  /// The next frame, without its length: a `u8` set for a key frame, then for a key frame its
  /// SPS and PPS each after a `u16` length, then the picture in AVCC. `nil` once the bridge has
  /// ended. Blocks until it comes.
  public func nextFrame() -> Data? {
    guard let header = read(4) else { return nil }
    return read(header.reduce(0) { $0 << 8 | Int($1) })
  }

  /// A line for the bridge, its newline included.
  public func send(_ line: String) {
    try? process.input.write(contentsOf: Data(line.utf8))
  }

  public func stop() {
    process.stop()
  }

  private func read(_ count: Int) -> Data? {
    var data = Data(capacity: count)
    while data.count < count {
      guard let part = try? process.output.read(upToCount: count - data.count), !part.isEmpty
      else { return nil }
      data.append(part)
    }
    return data
  }
}
