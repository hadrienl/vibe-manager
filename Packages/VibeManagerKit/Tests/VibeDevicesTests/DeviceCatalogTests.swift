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

  @Test("A file left by an emulator gone, whose pid another process has since, lists nothing")
  func recycledPid() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // This process's pid, in a file written before it started: an emulator's of last week.
    let file = folder.appendingPathComponent("pid_\(getpid()).ini")
    try "grpc.port=8554\navd.name=Gone\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.creationDate: Date(timeIntervalSinceNow: -7 * 86_400)], ofItemAtPath: file.path)
    #expect(DeviceCatalog.emulators(in: folder).isEmpty)
  }

  @Test("The phones of adb devices -l, by model, the emulators left out, the others unavailable")
  func phones() {
    let listed = DeviceCatalog.phones(
      listedIn: """
        List of devices attached
        R5CT1234ABC            device usb:1-1 product:shiba model:Pixel_8 device:shiba transport_id:1
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64 transport_id:2
        192.168.1.5:5555       device product:a54x model:SM_A546B device:a54x transport_id:3
        NOAUTH                 unauthorized usb:1-2 transport_id:4
        GONE                   offline transport_id:5
        BOOT                   bootloader transport_id:6

        """)
    #expect(listed.devices.map(\.name) == ["Pixel 8", "SM A546B"])
    #expect(
      listed.devices.map { DeviceCatalog.serial(ofPhone: $0.id) } == [
        "R5CT1234ABC", "192.168.1.5:5555",
      ])
    #expect(
      listed.unavailable == [
        .init(serial: "NOAUTH", problem: .unauthorized), .init(serial: "GONE", problem: .offline),
      ])
  }

  @Test("A phone's id fits the host of a URL, whatever its serial, and leads back to it")
  func phoneID() throws {
    for serial in ["R5CT1234ABC", "192.168.1.5:5555", "adb-XYZ._adb-tls-connect._tcp"] {
      let id = DeviceCatalog.phoneID(of: serial)
      let url = try #require(DeviceCatalog.url(of: id))
      #expect(url.host == id)
      #expect(DeviceCatalog.serial(ofPhone: id) == serial)
      #expect(DeviceCatalog.isPhone(id) && !DeviceCatalog.canStop(id))
    }
    #expect(DeviceCatalog.serial(ofPhone: "adb-zz") == nil)
    #expect(DeviceCatalog.serial(ofPhone: "android-8554") == nil)
    #expect(DeviceCatalog.canStop("android-8554") && DeviceCatalog.canStop("B6A3C2D1"))
  }

  @Test("adb is the SDK's first, then Android Studio's, then Homebrew's")
  func adb() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let studio = "/Users/someone/Library/Android/sdk/platform-tools/adb"
    func found(_ environment: [String: String], _ installed: Set<String>) -> String? {
      DeviceCatalog.adb(environment: environment, home: home, isExecutable: installed.contains)
    }
    #expect(
      found(["ANDROID_HOME": "/sdk"], ["/sdk/platform-tools/adb", studio])
        == "/sdk/platform-tools/adb")
    #expect(found(["ANDROID_HOME": "/sdk"], [studio, "/opt/homebrew/bin/adb"]) == studio)
    #expect(found([:], ["/usr/local/bin/adb"]) == "/usr/local/bin/adb")
    #expect(found([:], []) == nil)
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
