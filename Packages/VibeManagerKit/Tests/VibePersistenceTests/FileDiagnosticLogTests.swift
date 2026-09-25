import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("File diagnostic log")
struct FileDiagnosticLogTests {
  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeDiagnostics-\(UUID().uuidString)", isDirectory: true)
    return url
  }

  private func lines(_ url: URL) -> [[String: Any]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
  }

  @Test("Events at or above the level are written, owner only, one line each")
  func writes() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("app.jsonl")
    let log = FileDiagnosticLog(url: url, origin: .app)

    log.record(.session, .debug, "session.debug")
    log.record(.session, .info, "session.created", ["count": .count(1)])
    log.record(.store, .error, "store.writeFailed", ["errno": .code(28)])
    log.flush()

    #expect(lines(url).map { $0["name"] as? String } == ["session.created", "store.writeFailed"])
    #expect(mode(url.path) == 0o600)
    #expect(mode(directory.path) == 0o700)
  }

  @Test("Verbose keeps debug events")
  func verbose() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("app.jsonl")
    let log = FileDiagnosticLog(url: url, origin: .app, minimumLevel: .debug)

    log.record(.perf, .debug, "perf.sample")
    log.flush()

    #expect(lines(url).count == 1)
  }

  @Test("Past its size the file rotates, and only one rotation is kept")
  func rotatesBySize() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("app.jsonl")
    let log = FileDiagnosticLog(url: url, origin: .app, maximumFileSize: 1024)

    for index in 0..<100 {
      log.record(.session, .info, "session.created", ["count": .count(index)])
    }
    log.flush()

    let size = { (url: URL) in
      (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }
    let rotated = directory.appendingPathComponent("app.1.jsonl")
    #expect(size(url) <= 1024)
    #expect(size(rotated) <= 1024)
    #expect(FileManager.default.fileExists(atPath: rotated.path))
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(contents) == ["app.jsonl", "app.1.jsonl"])
    // The newest line is in the current file.
    #expect(lines(url).last?["fields"].flatMap { ($0 as? [String: Any])?["count"] as? Int } == 99)
  }

  @Test("A rotation whose last line is more than a week old is removed")
  func removesStaleRotation() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rotated = directory.appendingPathComponent("app.1.jsonl")
    FileManager.default.createFile(atPath: rotated.path, contents: Data("{}\n".utf8))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: rotated.path)

    let log = FileDiagnosticLog(url: directory.appendingPathComponent("app.jsonl"), origin: .app)
    log.record(.lifecycle, .info, "app.launched")
    log.flush()

    #expect(!FileManager.default.fileExists(atPath: rotated.path))
  }

  @Test("Lines that could not be written are counted, and the count is written later")
  func countsDropped() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("app.jsonl")
    // A folder where the file should be: nothing can be opened.
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let log = FileDiagnosticLog(url: url, origin: .app)

    log.record(.session, .info, "session.created")
    log.record(.session, .info, "session.created")
    log.flush()
    try FileManager.default.removeItem(at: url)
    log.record(.session, .info, "session.launched")
    log.flush()

    let written = lines(url)
    #expect(
      written.map { $0["name"] as? String } == ["diagnostics.linesDropped", "session.launched"])
    #expect((written.first?["fields"] as? [String: Any])?["count"] as? Int == 2)
  }

  @Test("The salt is created once, owner only, and read back after")
  func salt() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = DiagnosticsLocation(directory: directory)

    let first = location.salt()
    let second = location.salt()

    #expect(first.count == 32)
    #expect(first == second)
    #expect(mode(directory.appendingPathComponent(".salt").path) == 0o600)
  }
}
