import Darwin
import Foundation
import VibeProcess

/// The simulators and emulators running on this Mac (#480), which a tab or the phone can show.
public enum DeviceCatalog {
  public struct Device: Sendable, Hashable {
    /// A simulator's UDID, or `android-<gRPC port>`.
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

  public static func running() async -> [Device] {
    await simulators() + emulators().map(\.device)
  }

  /// Shuts a simulator down, or ends an emulator as closing its window would.
  public static func stop(_ id: String) async {
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
      ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "DEVELOPER_DIR"].contains($0.key)
    }
  }

  static let androidPrefix = "android-"

  // MARK: - Simulators

  private static func simulators() async -> [Device] {
    let request = simctl(["list", "devices", "booted", "-j"], timeout: .seconds(20))
    guard let result = try? await BoundedProcess.run(request), result.exitCode == 0 else {
      return []
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
        let text = try? String(contentsOf: file, encoding: .utf8),
        let device = emulator(described: text)
      else { return nil }
      return Emulator(processIdentifier: pid, device: device)
    }
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
}
