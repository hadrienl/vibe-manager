import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

private func temporaryFolder() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "AlertSoundStorageTests-\(UUID().uuidString)", isDirectory: true)
}

private let wave = AlertSoundWave.encode([0, 0.25, -0.25, 0], sampleRate: 8)

@Suite("The user's own sounds on disk (#393)")
struct FileAlertSoundLibraryTests {
  @Test("Added, renamed, read again by another instance, then deleted with its file")
  func lifecycle() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = FileAlertSoundLibrary(directory: folder)
    let added = try await library.add(
      AlertSoundEntry(
        name: "  Gong\nsecond line", origin: .imported, addedAt: Date(timeIntervalSince1970: 10),
        duration: 0.5),
      wave: wave)
    #expect(added.name == "Gong")
    #expect(added.byteCount == Int64(wave.count))
    try await library.rename(added.id, to: "Gong du bureau")

    let again = FileAlertSoundLibrary(directory: folder)
    let entries = try await again.entries()
    #expect(entries.map(\.name) == ["Gong du bureau"])
    #expect(entries.first?.addedAt == Date(timeIntervalSince1970: 10))
    let file = try await again.fileURL(of: added.id)
    #expect(try Data(contentsOf: file) == wave)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)

    try await again.remove(added.id)
    #expect(try await again.entries().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test("A composed sound replaced keeps its identifier, name and place, with its new recipe")
  func replace() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = FileAlertSoundLibrary(directory: folder)
    let first = try await library.add(
      AlertSoundEntry(
        name: "Premier", origin: .composed(agent: "codex"), addedAt: Date(), duration: 1,
        recipe: BundledAlertSound.chime.recipe, requests: ["un carillon"]),
      wave: wave)
    _ = try await library.add(
      AlertSoundEntry(name: "Second", origin: .imported, addedAt: Date(), duration: 1), wave: wave)
    var changed = first
    changed.name = "Ignored"
    changed.recipe = BundledAlertSound.drop.recipe
    changed.requests = ["un carillon", "plus court"]
    let longer = AlertSoundWave.encode([0, 0.1, 0.2, 0.1, 0], sampleRate: 8)
    let replaced = try await library.replace(first.id, with: changed, wave: longer)
    #expect(replaced.name == "Premier")
    let entries = try await FileAlertSoundLibrary(directory: folder).entries()
    #expect(entries.map(\.name) == ["Premier", "Second"])
    #expect(entries[0].recipe == BundledAlertSound.drop.recipe)
    #expect(entries[0].requests == ["un carillon", "plus court"])
    #expect(try Data(contentsOf: try await library.fileURL(of: first.id)) == longer)
  }

  @Test("A blank name, or an unknown sound, is refused and changes nothing")
  func refused() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = FileAlertSoundLibrary(directory: folder)
    await #expect(throws: AlertSoundLibraryError.emptyName) {
      try await library.add(
        AlertSoundEntry(name: " ", origin: .imported, addedAt: Date(), duration: 1), wave: wave)
    }
    await #expect(throws: AlertSoundLibraryError.notFound) {
      try await library.rename(AlertSoundID(), to: "Name")
    }
    #expect(try await library.entries().isEmpty)
  }

  @Test("An index that cannot be read is set aside, never written over; its sounds stay")
  func unreadableIndex() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{damaged".utf8).write(to: folder.appendingPathComponent("library.json"))
    let kept = folder.appendingPathComponent("\(UUID().uuidString).wav")
    try wave.write(to: kept)
    let library = FileAlertSoundLibrary(directory: folder)
    #expect(try await library.entries().isEmpty)
    _ = try await library.add(
      AlertSoundEntry(name: "New", origin: .imported, addedAt: Date(), duration: 1), wave: wave)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(names.contains { $0.hasPrefix("library.unreadable-") })
    #expect(FileManager.default.fileExists(atPath: kept.path))
  }
}

extension FileAlertSoundLibraryTests {
  @Test("An index of a later version is read as empty, never moved nor written to")
  func laterIndex() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let index = folder.appendingPathComponent("library.json")
    let later = Data(#"{"version":2,"sounds":[{"what":"comes later"}]}"#.utf8)
    try later.write(to: index)
    let library = FileAlertSoundLibrary(directory: folder)
    #expect(try await library.entries().isEmpty)
    await #expect(throws: AlertSoundLibraryError.storage) {
      try await library.add(
        AlertSoundEntry(name: "New", origin: .imported, addedAt: Date(), duration: 1), wave: wave)
    }
    #expect(try Data(contentsOf: index) == later)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!names.contains { $0.hasPrefix("library.unreadable-") })
  }
}

@Suite("Audio files read for an import (#393)")
struct AudioFileAlertSoundDecoderTests {
  @Test("A WAV of two channels is read as one, at its rate")
  func reads() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("beep.wav")
    let samples = (0..<4_410).map { Float(sin(Double($0) / 10)) * 0.5 }
    try AlertSoundWave.encode(samples, sampleRate: 44_100).write(to: url)
    let sound = try AudioFileAlertSoundDecoder().decode(url, maximumDuration: 30)
    #expect(sound.sampleRate == 44_100)
    #expect(sound.samples.count == 4_410)
    #expect(abs(sound.duration - 0.1) < 0.001)
  }

  @Test("Longer than allowed: refused with its length, without being read")
  func tooLong() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("long.wav")
    try AlertSoundWave.encode(Array(repeating: 0.1, count: 8_000 * 2), sampleRate: 8_000).write(
      to: url)
    #expect(throws: AlertSoundImportProblem.tooLong(2)) {
      try AudioFileAlertSoundDecoder().decode(url, maximumDuration: 1)
    }
  }

  @Test("What is not audio is unreadable")
  func garbage() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("notes.m4a")
    try Data("not a sound at all".utf8).write(to: url)
    #expect(throws: AlertSoundImportProblem.unreadable) {
      try AudioFileAlertSoundDecoder().decode(url, maximumDuration: 30)
    }
  }
}

@Suite("The sound in use, where the notifications find it (#393)")
struct NotificationSoundFolderTests {
  @Test("One file of the application's, replaced by the next; another copy's is left alone")
  func installs() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let other = folder.appendingPathComponent("Vibe Manager #393 abc – Gong.wav")
    let foreign = folder.appendingPathComponent("codex-alert.wav")
    try wave.write(to: other)
    try wave.write(to: foreign)
    let source = folder.appendingPathComponent("source.wav")
    try wave.write(to: source)

    let sounds = NotificationSoundFolder(applicationName: "Vibe Manager", directory: folder)
    #expect(try sounds.install(source, name: "Carillon/doux") == "Vibe Manager – Carillon-doux.wav")
    #expect(try sounds.install(source, name: "Goutte") == "Vibe Manager – Goutte.wav")
    var names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    #expect(names.contains("Vibe Manager – Goutte.wav"))
    #expect(!names.contains("Vibe Manager – Carillon-doux.wav"))

    sounds.clear()
    names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    #expect(!names.contains("Vibe Manager – Goutte.wav"))
    #expect(names.contains(other.lastPathComponent))
    #expect(names.contains(foreign.lastPathComponent))
  }

  @Test("A name of many bytes, or with what cannot be seen, still makes a file; no copy is left")
  func longNames() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("source.wav")
    try wave.write(to: source)
    let sounds = NotificationSoundFolder(applicationName: "Vibe Manager", directory: folder)

    let coders = String(repeating: "👩🏽‍💻", count: 60)
    let installed = try sounds.install(source, name: coders)
    #expect(installed.utf8.count <= 255)
    #expect(installed.hasPrefix("Vibe Manager – 👩🏽‍💻"))
    let marks = "e" + String(repeating: "\u{301}", count: 300)
    #expect(try sounds.install(source, name: marks).utf8.count <= 255)
    #expect(
      try sounds.install(source, name: "Bip\u{202E}vaw.exe") == "Vibe Manager – Bipvaw.exe.wav")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(!names.contains { $0.hasSuffix(".tmp") })
  }
}

@MainActor
@Suite("The alert sound chosen, kept across launches (#393)")
struct UserDefaultsAlertSoundPreferencesTests {
  @Test("Never written, or written by a later version: the system's default")
  func defaults() throws {
    let suite = "AlertSoundPreferencesTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsAlertSoundPreferences(suiteName: suite)
    #expect(preferences.alertSound == .systemDefault)
    preferences.alertSound = .macOS("Glass")
    #expect(UserDefaultsAlertSoundPreferences(suiteName: suite).alertSound == .macOS("Glass"))
    UserDefaults(suiteName: suite)?.set("hologram:x", forKey: "requests.alertSound.v1")
    #expect(UserDefaultsAlertSoundPreferences(suiteName: suite).alertSound == .systemDefault)
  }
}
