import Foundation
import Testing

@testable import VibePersistence

@Suite("Data directory permissions")
struct DataDirectoryPermissionsTests {
  private func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? Int) ?? -1
  }

  @Test("Folders and the files directly in them lose what the group and the others could do")
  func tightens() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibePermissions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let notes = root.appendingPathComponent("Notes", isDirectory: true)
    try FileManager.default.createDirectory(
      at: notes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    let store = root.appendingPathComponent("sessions.json")
    FileManager.default.createFile(
      atPath: store.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
    let tidy = root.appendingPathComponent("runtime.json")
    FileManager.default.createFile(
      atPath: tidy.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o600])

    let repaired = DataDirectoryPermissions.repair([root, notes])

    #expect(try mode(root.path) == 0o700)
    #expect(try mode(notes.path) == 0o700)
    #expect(try mode(store.path) == 0o600)
    #expect(
      Set(repaired.map(\.lastPathComponent)) == [root.lastPathComponent, "Notes", "sessions.json"])
    #expect(DataDirectoryPermissions.repair([root, notes]).isEmpty)
  }

  @Test("A missing folder is skipped, and a symbolic link is never followed")
  func leavesLinksAlone() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibePermissions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(
      at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

    let repaired = DataDirectoryPermissions.repair([
      link, root.appendingPathComponent("missing", isDirectory: true),
    ])

    #expect(repaired.isEmpty)
    #expect(try mode(elsewhere.path) == 0o755)
  }
}
