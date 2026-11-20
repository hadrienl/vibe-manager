import Darwin
import Foundation
import VibeProcess

/// The simulators and emulators running on this Mac (#480), and the Android phones connected to it
/// (#526), which a tab or the phone can show.
public enum DeviceCatalog {
  public struct Device: Sendable, Hashable {
    /// A simulator's UDID, `android-<gRPC port>`, or `adb-<serial in hexadecimal>`.
    public let id: String
    public let name: String
    /// What an emulator started with `-grpc-use-token` asks of its clients.
    public let token: String?

    public init(id: String, name: String, token: String? = nil) {
      self.id = id
      self.name = name
      self.token = token
    }
  }

  public static func url(of id: String) -> URL? {
    URL(string: "vibe-device://\(id)")
  }

  /// A phone adb sees but cannot show yet.
  public struct UnavailablePhone: Sendable, Hashable {
    public enum Problem: Sendable, Hashable {
      /// Its user has not accepted this Mac's key yet.
      case unauthorized
      case offline
    }

    public let serial: String
    public let problem: Problem
  }

  public struct Listing: Sendable, Hashable {
    public let devices: [Device]
    public let unavailablePhones: [UnavailablePhone]
    /// Whether adb was found: without it, no phone can be listed.
    public let hasADB: Bool
    /// A shared simulator probe is still running; a later listing can contain more simulators.
    public let isDiscoveringSimulators: Bool
  }

  public static func running() async -> [Device] {
    await listing().devices
  }

  /// Resolve only the requested device family: opening a phone never probes simulators.
  public static func device(id: String) async -> Device? {
    if isPhone(id) { return await phones().devices.first { $0.id == id } }
    if id.hasPrefix(androidPrefix) { return emulators().map(\.device).first { $0.id == id } }
    return await simulators().first { $0.id == id }
  }

  private static let simulatorDiscovery = SimulatorDiscovery { await probeSimulators() }

  /// Uses the last simulator snapshot, refreshed in the background. On a cold cache only,
  /// allow up to 200 ms for simctl, independently of adb. A picker may load simulators separately.
  public static func listing(includeSimulators: Bool = true) async -> Listing {
    async let simulators = includeSimulators ? simulatorDiscovery.snapshot() : nil
    let phones = await self.phones()
    let snapshot = await simulators
    return Listing(
      devices: (snapshot?.devices ?? []) + emulators().map(\.device) + phones.devices,
      unavailablePhones: phones.unavailable, hasADB: phones.hasADB,
      isDiscoveringSimulators: snapshot?.isRefreshing ?? false)
  }

  public static func isPhone(_ id: String) -> Bool {
    id.hasPrefix(phonePrefix)
  }

  /// Whether the device is the Mac's to stop: a phone is not.
  public static func canStop(_ id: String) -> Bool {
    !isPhone(id)
  }

  /// Shuts a simulator down, or ends an emulator as closing its window would.
  public static func stop(_ id: String) async {
    guard canStop(id) else { return }
    if id.hasPrefix(androidPrefix) {
      if let emulator = emulators().first(where: { $0.device.id == id }) {
        kill(emulator.processIdentifier, SIGTERM)
      }
      return
    }
    _ = try? await BoundedProcess.run(simctl(["shutdown", id], timeout: .seconds(60)))
  }

  /// What the bridges and `simctl` are given: enough to find the user's devices, nothing more.
  static var environment: [String: String] {
    ProcessInfo.processInfo.environment.filter {
      ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "DEVELOPER_DIR", "ANDROID_ADB_SERVER_PORT"]
        .contains($0.key)
    }
  }

  static let androidPrefix = "android-"
  static let phonePrefix = "adb-"

  // MARK: - Simulators

  /// Booted iOS simulators. Independent of adb: either discovery may take longer than the other.
  public static func simulators() async -> [Device] {
    await probeSimulators() ?? []
  }

  private static func probeSimulators() async -> [Device]? {
    let request = simctl(["list", "devices", "booted", "-j"], timeout: .seconds(20))
    guard let result = try? await BoundedProcess.run(request), result.exitCode == 0 else {
      return nil
    }
    return simulators(listedIn: result.standardOutput)
  }

  /// The devices of `simctl list devices -j`.
  static func simulators(listedIn json: Data) -> [Device] {
    guard
      let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let runtimes = root["devices"] as? [String: [[String: Any]]]
    else { return [] }
    return runtimes.values.flatMap { $0 }.compactMap { device in
      guard let id = device["udid"] as? String, let name = device["name"] as? String else {
        return nil
      }
      return Device(id: id, name: name)
    }
    .sorted { $0.name < $1.name }
  }

  private static func simctl(_ arguments: [String], timeout: Duration) -> BoundedProcessRequest {
    BoundedProcessRequest(
      executablePath: "/usr/bin/xcrun", arguments: ["simctl"] + arguments,
      environment: environment, timeout: timeout, outputByteLimit: 8 << 20)
  }

  // MARK: - Emulators

  struct Emulator {
    let processIdentifier: pid_t
    let device: Device
  }

  /// The emulators running now, as each lists itself in a `pid_<pid>.ini` while it runs.
  static func emulators(
    in folder: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
  ) -> [Emulator] {
    let files =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []
    return files.compactMap { file in
      let stem = file.deletingPathExtension().lastPathComponent
      guard stem.hasPrefix("pid_"), let pid = pid_t(stem.dropFirst(4)), kill(pid, 0) == 0,
        isWriter(pid, of: file), let text = try? String(contentsOf: file, encoding: .utf8),
        let device = emulator(described: text)
      else { return nil }
      return Emulator(processIdentifier: pid, device: device)
    }
  }

  /// Whether `pid` is still the process that listed itself in `file`: started before the file was
  /// written. An emulator that crashed leaves its file, and its pid may since be another process
  /// of the user's — which Stop would end.
  static func isWriter(_ pid: pid_t, of file: URL) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      let written = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    else { return false }
    let started = Date(
      timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    // Whole seconds in some file systems' dates.
    return started <= written.addingTimeInterval(1)
  }

  /// The device a `pid_<pid>.ini` describes, if it serves gRPC.
  static func emulator(described text: String) -> Device? {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
    }
    guard let port = values["grpc.port"] else { return nil }
    return Device(
      id: androidPrefix + port, name: values["avd.name"] ?? "Android", token: values["grpc.token"])
  }

  // MARK: - Phones

  /// The user's adb, where Android Studio, the SDK's variables or Homebrew put it.
  static func adb(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
  ) -> String? {
    let sdks =
      [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
      + [home.appendingPathComponent("Library/Android/sdk").path]
    let candidates =
      sdks.map { URL(fileURLWithPath: $0).appendingPathComponent("platform-tools/adb").path }
      + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
    return candidates.first(where: isExecutable)
  }

  /// Starts the adb server if it is not running, as listing the phones does: what a bridge
  /// opened from a tab restored at launch talks to.
  static func startADBServer() async {
    guard let adb = adb() else { return }
    _ = try? await BoundedProcess.run(adbRequest(adb, ["start-server"]))
  }

  private static func phones() async -> (
    devices: [Device], unavailable: [UnavailablePhone], hasADB: Bool
  ) {
    guard let adb = adb() else { return ([], [], false) }
    guard let result = try? await BoundedProcess.run(adbRequest(adb, ["devices", "-l"])),
      result.exitCode == 0
    else { return ([], [], true) }
    let listed = phones(listedIn: String(decoding: result.standardOutput, as: UTF8.self))
    return (listed.devices, listed.unavailable, true)
  }

  /// The phones of `adb devices -l`, the emulators left out: they are shown by their gRPC.
  static func phones(listedIn text: String) -> (devices: [Device], unavailable: [UnavailablePhone])
  {
    var devices: [Device] = []
    var unavailable: [UnavailablePhone] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 2, !fields[0].hasPrefix("emulator-") else { continue }
      let serial = String(fields[0])
      switch fields[1] {
      case "device":
        let model = fields.first { $0.hasPrefix("model:") }?.dropFirst(6)
        let name = model.map { $0.replacingOccurrences(of: "_", with: " ") } ?? serial
        devices.append(Device(id: phoneID(of: serial), name: name))
      case "unauthorized", "authorizing":
        unavailable.append(UnavailablePhone(serial: serial, problem: .unauthorized))
      case "offline":
        unavailable.append(UnavailablePhone(serial: serial, problem: .offline))
      default:
        continue
      }
    }
    return (devices.sorted { $0.name < $1.name }, unavailable)
  }

  /// In hexadecimal: a serial over Wi-Fi holds `:` and dots, which the host of a
  /// `vibe-device://` URL cannot.
  static func phoneID(of serial: String) -> String {
    phonePrefix + serial.utf8.map { String(format: "%02x", $0) }.joined()
  }

  static func serial(ofPhone id: String) -> String? {
    guard id.hasPrefix(phonePrefix) else { return nil }
    let hex = Array(id.dropFirst(phonePrefix.count).utf8)
    guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    for index in stride(from: 0, to: hex.count, by: 2) {
      guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16)
      else { return nil }
      bytes.append(byte)
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  private static func adbRequest(_ adb: String, _ arguments: [String]) -> BoundedProcessRequest {
    BoundedProcessRequest(
      executablePath: adb, arguments: arguments, environment: environment, timeout: .seconds(20),
      outputByteLimit: 1 << 20)
  }
}
