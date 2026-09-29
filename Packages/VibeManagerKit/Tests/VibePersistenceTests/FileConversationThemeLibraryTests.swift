import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibePersistence

@Suite("The personal themes on disk (#118)")
struct FileConversationThemeLibraryTests {
  private let root: URL
  private let directory: URL
  private let log = RecordingDiagnosticLog()

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-themes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    directory = root.appendingPathComponent("Themes", isDirectory: true)
  }

  private func library() -> FileConversationThemeLibrary {
    FileConversationThemeLibrary(
      directory: directory, diagnostics: Diagnostics(log: log, pseudonym: .ephemeral()),
      localizedBuiltInNames: ["Papier"])
  }

  private func permissions(_ url: URL) throws -> Int {
    try #require(
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  @Test("No folder is an empty library")
  func empty() async {
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = await library().load()
    #expect(contents.themes.isEmpty)
    #expect(contents.problems.isEmpty)
  }

  @Test("A theme saved is read back by another instance, in a private folder")
  func saveAndReload() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await library().save(.night, name: "Forêt de nuit")
    #expect(saved.isPersonal)
    #expect(saved.personalName == "Forêt de nuit")
    let contents = await library().load()
    #expect(contents.themes == [saved])
    let file = library().file(of: saved.id)
    #expect(file.lastPathComponent == "\(saved.id.dropFirst(9)).json")
    #expect(try permissions(directory) == 0o700)
    #expect(try permissions(file) == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers == [file.lastPathComponent])
  }

  @Test("A name taken — by a theme of the library or a built-in one — gets a number")
  func uniqueNames() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await library().save(.night, name: "Forêt")
    let second = try await library().save(.night, name: "foret")
    let paper = try await library().save(.paper, name: "papier")
    #expect(first.personalName == "Forêt")
    #expect(second.personalName == "foret 2")
    #expect(paper.personalName == "papier 2")
    // Saving a theme again keeps its own name free for it.
    let renamed = try await library().save(first, name: "Forêt")
    #expect(renamed.personalName == "Forêt")
    #expect(renamed.id == first.id)
    #expect(await library().load().themes.count == 3)
  }

  @Test("A file that cannot be read is left out, left in place and said, the others loaded")
  func invalidFiles() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await library().save(.night, name: "Nuit")
    var object = try #require(
      try JSONSerialization.jsonObject(with: ConversationThemeFile.encode(saved))
        as? [String: Any])
    var colors = try #require(object["colors"] as? [String: Any])
    colors["keyword"] = nil
    object["colors"] = colors
    let broken = directory.appendingPathComponent("broken.json")
    try JSONSerialization.data(withJSONObject: object).write(to: broken)
    try Data("{".utf8).write(to: directory.appendingPathComponent("garbage.json"))
    try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))

    let contents = await library().load()
    #expect(contents.themes.map(\.id) == [saved.id])
    #expect(
      Set(contents.problems) == [
        ThemeLoadProblem(fileName: "broken.json", problem: .missingKey("colors.keyword")),
        ThemeLoadProblem(fileName: "garbage.json", problem: .notJSON),
      ])
    #expect(FileManager.default.fileExists(atPath: broken.path))
    let unreadable = log.events(named: "theme.unreadable")
    #expect(unreadable.count == 2)
    #expect(unreadable.allSatisfy { $0.value(of: "problem") != nil })
  }

  @Test("A theme whose colours no longer read is left out like an unreadable one")
  func illegibleFile() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var theme = ConversationThemeLibraryRules.kept(.night, name: "Gris")
    theme.text = theme.background
    try ConversationThemeFile.encode(theme).write(to: library().file(of: theme.id))
    let contents = await library().load()
    #expect(contents.themes.isEmpty)
    #expect(contents.problems.first?.problem.code == .illegible)
  }

  @Test("Removing deletes the file, and a theme that is not there says so")
  func remove() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await library().save(.night, name: "Nuit")
    try await library().remove(saved.id)
    #expect(await library().load().themes.isEmpty)
    await #expect(throws: ThemeLibraryError.notFound) { try await library().remove(saved.id) }
  }

  @Test("The archive holds the theme's file, and its preview when there is one")
  func archive() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await library().save(.paper, name: "Papier crème")
    let preview = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let url = root.appendingPathComponent("export.zip")
    try await library().archive(saved.id, preview: preview).write(to: url)

    let theme = try await unzip(url, "theme.json")
    #expect(try ConversationThemeFile.theme(from: theme, id: "personal-x").colors == saved.colors)
    #expect(try await unzip(url, "preview.png") == preview)

    let alone = root.appendingPathComponent("alone.zip")
    try await library().archive(saved.id, preview: nil).write(to: alone)
    let list = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/unzip", arguments: ["-Z1", alone.path], environment: [:],
        timeout: .seconds(20)))
    #expect(String(decoding: list.standardOutput, as: UTF8.self) == "theme.json\n")
    await #expect(throws: ThemeLibraryError.notFound) {
      try await library().archive("personal-missing", preview: nil)
    }
  }

  private func unzip(_ archive: URL, _ name: String) async throws -> Data {
    let read = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/unzip", arguments: ["-p", archive.path, name], environment: [:],
        timeout: .seconds(20)))
    #expect(read.termination == .exited(0))
    return read.standardOutput
  }
}
