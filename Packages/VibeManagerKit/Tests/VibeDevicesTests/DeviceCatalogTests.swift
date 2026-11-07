import Foundation
import Testing

@testable import VibeDevices

@Suite("Device catalog")
struct DeviceCatalogTests {
  @Test("An emulator is named after its AVD and found by its gRPC port, with its token if any")
  func emulator() {
    let device = DeviceCatalog.emulator(
      described: "avd.name=Pixel_10_Pro\ngrpc.port=8554\ngrpc.token=secret\nport.serial=5554\n")
    #expect(device == .init(id: "android-8554", name: "Pixel_10_Pro", token: "secret"))
  }

  @Test("An emulator that serves no gRPC cannot be shown")
  func emulatorWithoutGRPC() {
    #expect(DeviceCatalog.emulator(described: "avd.name=Pixel\nport.serial=5554\n") == nil)
  }

  @Test("Only the emulators whose process still runs are listed")
  func runningEmulators() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let alive = getpid()
    try "grpc.port=8554\navd.name=Alive\n".write(
      to: folder.appendingPathComponent("pid_\(alive).ini"), atomically: true, encoding: .utf8)
    try "grpc.port=8556\navd.name=Gone\n".write(
      to: folder.appendingPathComponent("pid_999999.ini"), atomically: true, encoding: .utf8)
    let emulators = DeviceCatalog.emulators(in: folder)
    #expect(emulators.map(\.device.name) == ["Alive"])
    #expect(emulators.first?.processIdentifier == alive)
  }

  @Test("The simulators booted, from simctl's JSON, sorted by name")
  func simulators() {
    let json = Data(
      """
      {"devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          {"udid": "B", "name": "iPhone 18 Pro", "state": "Booted"},
          {"udid": "A", "name": "iPad Air", "state": "Booted"}
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [{"name": "No UDID"}]
      }}
      """.utf8)
    #expect(DeviceCatalog.simulators(listedIn: json).map(\.id) == ["A", "B"])
    #expect(DeviceCatalog.simulators(listedIn: Data("not json".utf8)).isEmpty)
  }

  @Test("A bridge's frames are read whole, one after the other, until it ends")
  func frames() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A stand-in bridge: two frames, of 3 and 1 bytes, then it ends.
    let bridge = folder.appendingPathComponent("sim-bridge")
    try "#!/bin/sh\nprintf '\\000\\000\\000\\003\\001ab\\000\\000\\000\\001\\000'\n".write(
      to: bridge, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
    let session = try DeviceBridge(device: "SIMULATOR", bridgesIn: folder)
    #expect(session.nextFrame() == Data([1, 0x61, 0x62]))
    #expect(session.nextFrame() == Data([0]))
    #expect(session.nextFrame() == nil)
    session.stop()
  }
}
