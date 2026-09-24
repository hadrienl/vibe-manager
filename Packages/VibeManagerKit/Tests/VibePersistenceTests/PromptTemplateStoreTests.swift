import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The prompt template store")
struct FilePromptTemplateRepositoryTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000.123)

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("templates-\(UUID().uuidString)", isDirectory: true)
    return url
  }

  @Test("Templates survive a round trip, in the order the user chose")
  func roundTrip() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FilePromptTemplateRepository(
      storeURL: directory.appendingPathComponent("templates.json"))
    let now = self.now

    try await store.update { library in
      library.addExamples(at: now)
      library.move(PromptTemplateExamples.feedbackID, toPosition: 0)
    }

    let reopened = FilePromptTemplateRepository(
      storeURL: directory.appendingPathComponent("templates.json"))
    let library = try await reopened.library()
    #expect(
      library.templates.map(\.id) == [
        PromptTemplateExamples.feedbackID, PromptTemplateExamples.reviewID,
      ])
    #expect(library.templates[1] == PromptTemplateExamples.review(createdAt: now))
  }

  @Test("Files are private to the user, and the previous version is backed up")
  func permissionsAndBackup() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("templates.json")
    let store = FilePromptTemplateRepository(storeURL: url)
    let now = self.now

    try await store.update { _ = $0.addExamples(at: now) }
    try await store.update { $0.delete(PromptTemplateExamples.reviewID) }

    let manager = FileManager.default
    let fileMode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    let folderMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(folderMode == 0o700)
    let backup = directory.appendingPathComponent("templates.backup.json")
    let previous = try PromptTemplateStoreCodec().decode(Data(contentsOf: backup))
    #expect(previous.templates.count == 2)
  }

  @Test(
    "A damaged file or one from a newer version is never written over",
    arguments: [
      "not json", #"{"schemaVersion": 2, "templates": []}"#,
    ])
  func unreadableIsKept(_ contents: String) async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("templates.json")
    try Data(contents.utf8).write(to: url)
    let store = FilePromptTemplateRepository(storeURL: url)
    let now = self.now

    await #expect(throws: PromptTemplateStoreError.self) { try await store.library() }
    await #expect(throws: PromptTemplateStoreError.self) {
      try await store.update { _ = $0.addExamples(at: now) }
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == contents)
  }

  @Test("A write interrupted before the file is replaced leaves the old one intact")
  func interruptedWrite() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("templates.json")
    let now = self.now
    try await FilePromptTemplateRepository(storeURL: url).update { _ = $0.addExamples(at: now) }
    let before = try Data(contentsOf: url)

    struct Interrupted: Error {}
    let failing = FilePromptTemplateRepository(
      storeURL: url, beforeReplace: { throw Interrupted() })
    await #expect(throws: (any Error).self) {
      try await failing.update { $0.delete(PromptTemplateExamples.reviewID) }
    }
    #expect(try Data(contentsOf: url) == before)
  }
}

@Suite("The folder of a template on disk")
struct PromptTemplateFolderStoreTests {
  @Test("The folder survives the store and an export, and a file without one reads as none")
  func folderRoundTrips() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("templates-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("templates.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let template = PromptTemplate(
      name: "API", body: "x", workingDirectoryPath: "~/Projects/api",
      appearance: SessionAppearance(symbolName: "bolt", colorHex: "#0B63E5"))
    let now = Date()
    try await FilePromptTemplateRepository(storeURL: url).update { library in
      _ = try library.save(template, at: now)
    }
    let stored = try await FilePromptTemplateRepository(storeURL: url).library()
    #expect(stored.templates.first?.workingDirectoryPath == "~/Projects/api")
    #expect(stored.templates.first?.appearance == template.appearance)

    let codec = PromptTemplateExchangeCodec()
    let exported = try codec.encode(stored.templates, exportedAt: now)
    #expect(
      try codec.decode(exported, importedAt: now).first?.workingDirectoryPath == "~/Projects/api")
    #expect(try codec.decode(exported, importedAt: now).first?.appearance == template.appearance)

    let withoutFolder = Data(
      #"{"format":"vibe-manager.prompt-templates","version":1,"templates":[{"id":"6F1C2A4E-7D35-4B8A-9E61-2C0D5B7A1E09","name":"N","body":"b"}]}"#
        .utf8)
    #expect(try codec.decode(withoutFolder, importedAt: now).first?.workingDirectoryPath == nil)
  }
}

@Suite("Exchanging templates")
struct PromptTemplateExchangeTests {
  private let codec = PromptTemplateExchangeCodec()
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test("An export imported into an empty library gives the same templates")
  func roundTrip() throws {
    var library = PromptTemplateLibrary()
    library.addExamples(at: now)
    let data = try codec.encode(library.templates, exportedAt: now)

    let incoming = try codec.decode(data, importedAt: now)
    var other = PromptTemplateLibrary()
    other.apply(other.planImport(incoming), at: now)
    #expect(other.templates.count == 2)
    #expect(zip(other.templates, library.templates).allSatisfy { $0.hasSameContent(as: $1) })

    // Imported again, nothing is new.
    let again = other.planImport(try codec.decode(data, importedAt: now))
    #expect(again.entries.allSatisfy { $0.outcome == .identical })
  }

  @Test("A file of a newer version, of another format or too large is refused whole")
  func refusals() throws {
    #expect(throws: PromptTemplateExchangeError.unsupportedVersion(2)) {
      try codec.decode(
        Data(#"{"format":"vibe-manager.prompt-templates","version":2,"templates":[]}"#.utf8),
        importedAt: now)
    }
    #expect(throws: PromptTemplateExchangeError.notATemplateFile) {
      try codec.decode(
        Data(#"{"format":"other","version":1,"templates":[]}"#.utf8), importedAt: now)
    }
    let large = Data(count: PromptTemplateExchangeCodec.byteLimit + 1)
    #expect(throws: PromptTemplateExchangeError.tooLarge(byteCount: large.count)) {
      try codec.decode(large, importedAt: now)
    }
  }

  @Test("The example in the documentation imports as documented")
  func documentedExample() throws {
    let docs = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/prompt-templates.md")
    let markdown = try String(contentsOf: docs, encoding: .utf8)
    let start = try #require(markdown.range(of: "```json\n{\n  \"format\""))
    let end = try #require(markdown.range(of: "\n```", range: start.upperBound..<markdown.endIndex))
    let json = String(markdown[markdown.index(start.lowerBound, offsetBy: 8)..<end.lowerBound])

    let templates = try codec.decode(Data(json.utf8), importedAt: now)
    #expect(templates.count == 1)
    let review = try #require(templates.first)
    #expect(review.fields.map(\.name) == ["url", "focus"])
    #expect(review.fields.map(\.isRequired) == [true, false])
    #expect(review.fields.last?.isMultiline == true)
    #expect(review.sessionNamePattern == #"Review {{url|/(?:merge_requests|pull)\/(\d+)/}}"#)
    #expect(review.extractions(for: "url").count == 1)
    #expect(review.workingDirectoryPath == "~/Projects/api")
  }
}
