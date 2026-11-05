import Foundation

/// The simulators and emulators running on this Mac, which a tab can show.
public enum DeviceCatalog {
  public struct Device: Sendable, Hashable {
    /// A simulator's UDID, or `android-<gRPC port>`.
    public let id: String
    public let name: String
    public let token: String?
  }

  public static func url(of id: String) -> URL? {
    URL(string: "vibe-device://\(id)")
  }

  /// Shuts down a simulator, or ends an emulator as its own window's close would.
  public static func stop(_ id: String) {
    if id.hasPrefix("android-") {
      if let pid = emulatorProcess(of: id) { kill(pid, SIGTERM) }
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "shutdown", id]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
  }

  private static func emulatorProcess(of id: String) -> Int32? {
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []
    let port = "grpc.port=\(id.dropFirst("android-".count))"
    for file in files {
      let stem = file.deletingPathExtension().lastPathComponent
      guard stem.hasPrefix("pid_"), let pid = Int32(stem.dropFirst(4)), kill(pid, 0) == 0,
        let text = try? String(contentsOf: file, encoding: .utf8),
        text.split(whereSeparator: \.isNewline).contains(where: { $0 == port })
      else { continue }
      return pid
    }
    return nil
  }

  public static func running() -> [Device] {
    simulators() + emulators()
  }

  public static func emulators() -> [Device] {
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []
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
      return Device(
        id: "android-\(port)", name: values["avd.name"] ?? "Android", token: values["grpc.token"])
    }
  }

  private static func simulators() -> [Device] {
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
      return Device(id: id, name: name, token: nil)
    }
  }
}
