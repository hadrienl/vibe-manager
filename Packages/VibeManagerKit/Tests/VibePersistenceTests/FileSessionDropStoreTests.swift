import Foundation
import Testing
import VibeDomain

@testable import VibePersistence

@Suite("The folder drops write into, per session (#42)")
struct FileSessionDropStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-drops-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Drops", isDirectory: true)
  }

  private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  @Test("Bytes are written under the name proposed, in a folder only the owner can open")
  func save() async throws {
    let root = directory()
    let store = FileSessionDropStore(directory: root)
    let id = SessionID()
    let url = try await store.save(Data([1, 2, 3]), suggestedName: "shot.png", for: id)
    #expect(url.lastPathComponent == "shot.png")
    #expect(url.deletingLastPathComponent().lastPathComponent == id.rawValue.uuidString)
    #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    #expect(try mode(of: url.deletingLastPathComponent()) == 0o700)
    #expect(try mode(of: root) == 0o700)
  }

  @Test("A name taken is suffixed, and a name that cannot be typed is cleaned first")
  func names() async throws {
    let store = FileSessionDropStore(directory: directory())
    let id = SessionID()
    let first = try await store.save(Data(), suggestedName: "shot.png", for: id)
    let second = try await store.save(Data(), suggestedName: "shot.png", for: id)
    let odd = try await store.save(Data(), suggestedName: "a/b\u{1B}.png", for: id)
    #expect(first.lastPathComponent == "shot.png")
    #expect(second.lastPathComponent == "shot (2).png")
    #expect(odd.lastPathComponent == "a-b .png")
  }

  @Test("A file about to disappear is copied, and the copy survives it")
  func copy() async throws {
    let store = FileSessionDropStore(directory: directory())
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-source-\(UUID().uuidString).txt")
    try Data("hello".utf8).write(to: source)
    let copy = try await store.copy(source, suggestedName: "Note.txt", for: SessionID())
    try FileManager.default.removeItem(at: source)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "hello")
  }

  @Test("Removing a session removes its folder, and only its folder")
  func remove() async throws {
    let store = FileSessionDropStore(directory: directory())
    let gone = SessionID()
    let kept = SessionID()
    let goneFile = try await store.save(Data(), suggestedName: "a", for: gone)
    let keptFile = try await store.save(Data(), suggestedName: "b", for: kept)
    await store.remove(gone)
    #expect(!FileManager.default.fileExists(atPath: goneFile.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: keptFile.path))
  }

  @Test("A sweep keeps the sessions named and nothing it did not write")
  func sweep() async throws {
    let root = directory()
    let store = FileSessionDropStore(directory: root)
    let kept = SessionID()
    let leftover = SessionID()
    let keptFile = try await store.save(Data(), suggestedName: "a", for: kept)
    let leftoverFile = try await store.save(Data(), suggestedName: "b", for: leftover)
    let stranger = root.appendingPathComponent("not-a-session")
    try Data().write(to: stranger)

    await store.sweep(keeping: [kept])

    #expect(FileManager.default.fileExists(atPath: keptFile.path))
    #expect(!FileManager.default.fileExists(atPath: leftoverFile.path))
    #expect(FileManager.default.fileExists(atPath: stranger.path))
  }

  @Test("A sweep with nothing written yet does nothing")
  func sweepWithoutFolder() async {
    await FileSessionDropStore(directory: directory()).sweep(keeping: [])
  }
}
