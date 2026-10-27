import Darwin
import Foundation
import Testing

@testable import VibeTerminal

@Suite struct TerminalHostCleanupTests {
  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("cleanup-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeRuntime(in root: URL, name: String, age: TimeInterval = 7200) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    backdate(directory, by: age)
    return directory
  }

  private func backdate(_ url: URL, by age: TimeInterval) {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
  }

  private func lock(_ directory: URL, _ name: String) -> Int32 {
    let descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    backdate(directory, by: 7200)
    return descriptor
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  @Test func removesADirectoryNobodyOwns() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = try makeRuntime(in: root, name: "aaaa")
    // A lock file nobody holds, left by a host that is gone.
    FileManager.default.createFile(
      atPath: stale.appendingPathComponent("host.lock").path, contents: nil)
    backdate(stale, by: 7200)

    let removed = TerminalHostCleanup.removeAbandoned(in: root)

    #expect(removed == ["aaaa"])
    #expect(!exists(stale))
  }

  @Test func keepsADirectoryWhoseHostHoldsTheLock() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try makeRuntime(in: root, name: "host")
    let descriptor = lock(live, "host.lock")
    defer { close(descriptor) }

    #expect(TerminalHostCleanup.removeAbandoned(in: root).isEmpty)
    #expect(exists(live))
  }

  @Test func keepsADirectoryAnApplicationClaimed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("app", isDirectory: true)
    let location = TerminalHostLocation(directory: directory)
    #expect(location.claim())
    backdate(directory, by: 7200)

    #expect(TerminalHostCleanup.removeAbandoned(in: root).isEmpty)
    #expect(exists(directory))
  }

  @Test func keepsADirectoryWithALiveSocket() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Short path: `sun_path` holds 104 bytes.
    let short = URL(fileURLWithPath: "/tmp/vc-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: short) }
    let live = try makeRuntime(in: short, name: "s")
    let listener = try UnixSocket.listen(at: live.appendingPathComponent("browser-v1.sock").path)
    defer { close(listener) }
    backdate(live, by: 7200)

    #expect(TerminalHostCleanup.removeAbandoned(in: short).isEmpty)
    #expect(exists(live))
  }

  @Test func removesADirectoryWithOnlyADeadSocket() throws {
    let short = URL(fileURLWithPath: "/tmp/vc-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: short) }
    let dead = try makeRuntime(in: short, name: "d")
    let path = dead.appendingPathComponent("browser-v1.sock").path
    close(try UnixSocket.listen(at: path))
    backdate(dead, by: 7200)

    #expect(TerminalHostCleanup.removeAbandoned(in: short) == ["d"])
  }

  @Test func keepsRecentDirectoriesTheCallersOwnAndStrayFiles() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recent = try makeRuntime(in: root, name: "recent", age: 60)
    let mine = try makeRuntime(in: root, name: "mine")
    FileManager.default.createFile(atPath: root.appendingPathComponent("note").path, contents: nil)
    backdate(root.appendingPathComponent("note"), by: 7200)

    #expect(TerminalHostCleanup.removeAbandoned(in: root, keeping: mine).isEmpty)
    #expect(exists(recent) && exists(mine))
    #expect(exists(root.appendingPathComponent("note")))
  }
}
