import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeProcess

@testable import VibePersistence

@Suite("Diagnostics export")
struct DiagnosticsExportTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func snapshot(logs: [DiagnosticSnapshot.Attachment] = []) -> DiagnosticSnapshot {
    DiagnosticSnapshot(
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      application: DiagnosticSnapshot.Application(
        version: DiagnosticVersion("1.0.0"), build: DiagnosticVersion("420"),
        operatingSystem: DiagnosticVersion("15.1.0"), architecture: "arm64", signature: "team",
        teamIdentifier: DiagnosticVersion("ABCDE12345"), hardenedRuntime: true),
      settings: DiagnosticSnapshot.Settings(
        quitBehavior: "ask", confirmsStoppingRunningAgent: true,
        fileEditor: "defaultApplication", verboseDiagnostics: false,
        isolatedData: false, terminalHost: true),
      agents: [
        DiagnosticSnapshot.Agent(
          provider: "codex", state: "available", version: DiagnosticVersion("0.155.1"),
          directory: RedactedPath("/opt/homebrew/bin"), source: "candidateDirectory",
          authentication: "authenticated", remediations: [],
          probedAt: Date(timeIntervalSince1970: 1_800_000_000))
      ],
      store: DiagnosticSnapshot.Store(
        schemaVersion: 4, sessionsByStatus: [.active: 2, .closed: 1], storeBytes: 2048,
        backupBytes: 1024, backupModifiedAt: nil, corruptCopies: 0, noteFiles: 1, noteBytes: 12),
      runtime: DiagnosticSnapshot.Runtime(
        phase: "running", updatedAt: nil, recordedSessions: 2, previousShutdown: "clean",
        host: DiagnosticSnapshot.Host(
          processIdentifier: 42, startedAt: nil, protocolVersion: 1,
          sessions: [
            DiagnosticSnapshot.HostSession(
              session: SessionPseudonym(SessionID(), salt: Data([1])), state: "running")
          ]),
        sessionsRunningInApplication: 0),
      logs: logs,
      crashReports: [])
  }

  @Test("The export is the four reports, then the logs and the crash reports")
  func files() {
    let files = DiagnosticArchive.files(
      from: Self.snapshot(
        logs: [DiagnosticSnapshot.Attachment(name: "app.jsonl", contents: Data("{}\n".utf8))]))

    #expect(
      files.map(\.name) == [
        "summary.txt", "agents.txt", "store.txt", "runtime.txt", "logs/app.jsonl",
      ])
    #expect(files[0].text.contains(DiagnosticArchive.exclusions))
    #expect(files[1].text.contains("Authentication: authenticated"))
    #expect(files[2].text.contains("active: 2"))
    #expect(files[3].text.contains("Previous shutdown: clean"))
    let preview = DiagnosticArchive.preview(of: files)
    for file in files { #expect(preview.contains("=== \(file.name)")) }
  }

  @Test("The archive is a ZIP the system reads back, file for file")
  func archive() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let big = String(repeating: "compressible line\n", count: 2000)
    let files = [
      DiagnosticFile(name: "summary.txt", contents: Data("hello\n".utf8)),
      DiagnosticFile(name: "logs/app.jsonl", contents: Data(big.utf8)),
      DiagnosticFile(name: "empty.txt", contents: Data()),
    ]
    let archive = ZipArchiveWriter.archive(files)
    let url = directory.appendingPathComponent("export.zip")
    try archive.write(to: url)

    #expect(archive.count < big.utf8.count)
    let test = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/unzip", arguments: ["-t", url.path], environment: [:],
        timeout: .seconds(20)))
    #expect(test.termination == .exited(0))
    for file in files {
      let read = try await BoundedProcess.run(
        BoundedProcessRequest(
          executablePath: "/usr/bin/unzip", arguments: ["-p", url.path, file.name],
          environment: [:], timeout: .seconds(20)))
      #expect(read.standardOutput == file.contents, "\(file.name)")
    }
  }

  @Test("Only the log lines of the last week are exported, and only diagnostic events")
  func filtersLogs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = DiagnosticsLocation(directory: directory)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recent = DiagnosticLine.encode(
      DiagnosticEvent(at: now.addingTimeInterval(-3600), .session, .info, "session.created"),
      origin: .app)
    let old = DiagnosticLine.encode(
      DiagnosticEvent(at: now.addingTimeInterval(-8 * 86400), .session, .info, "session.old"),
      origin: .app)
    var contents = old + recent
    contents.append(Data("not json at all\n".utf8))
    try contents.write(to: location.applicationLog)

    let logs = DiagnosticsCollector.logs(in: location, now: now)

    #expect(logs.map(\.name) == ["app.jsonl"])
    #expect(logs.first?.contents == recent)
  }

  @Test("A crash report's paths under the home folder are redacted, and so is the user name")
  func redactsCrashReports() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = """
      {"procPath":"/Users/alice/Applications/Vibe Manager.app/Contents/MacOS/Vibe Manager",
      "cwd":"/Users/alice/Projects/secret-client","user":"alice"}
      """
    try Data(report.utf8).write(
      to: directory.appendingPathComponent("Vibe Manager-2026-09-24-101010.ips"))
    try Data(report.utf8).write(to: directory.appendingPathComponent("Other App-2026.ips"))

    let reports = DiagnosticsCollector.crashReports(in: directory, home: "/Users/alice")

    #expect(reports.map(\.name) == ["Vibe Manager-2026-09-24-101010.ips"])
    let text = String(decoding: reports[0].contents, as: UTF8.self)
    #expect(!text.contains("alice"))
    #expect(!text.contains("secret-client"))
    #expect(!text.contains("Projects"))
    #expect(text.contains("\"cwd\":\"~/"))
  }

  @Test("The store is sizes and counts, never a session")
  func store() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("sessions.json")
    let repository = FileSessionRepository(storeURL: storeURL)
    let session = WorkSession(name: "Client secret project", status: .active)
    try await repository.save(session)
    try await repository.save(session)
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("sessions.corrupt-1.json").path, contents: Data())
    let notes = directory.appendingPathComponent("Notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    try Data("note".utf8).write(to: notes.appendingPathComponent("x.txt"))

    let store = DiagnosticsCollector.store(
      storeURL: storeURL, notesDirectory: notes, statuses: [.active, .active, .closed])

    #expect(store.schemaVersion == 4)
    #expect(store.sessionsByStatus == [.active: 2, .closed: 1])
    #expect((store.storeBytes ?? 0) > 0)
    #expect(store.backupBytes != nil)
    #expect(store.corruptCopies == 1)
    #expect(store.noteFiles == 1)
    #expect(store.noteBytes == 4)
  }
}
