import Foundation
import Testing
import VibeApplication
import VibeComposition
import VibeDomain
import VibeGit
import VibePersistence

@testable import VibeUI

/// The acceptance criterion "no prompt, token or secret appears in the logs by default", proved
/// rather than promised: one marker put everywhere the user's words go, and looked for everywhere
/// the application writes about itself.
@MainActor
@Suite("Canary", .serialized, .timeLimit(.minutes(3)))
struct CanaryScenarioTests {
  @Test("A canary in a session's name, prompt, notes, folder, proxy and terminal reaches no log")
  func canary() async throws {
    let canary = "VIBE-CANARY-\(UUID().uuidString)"
    let scenario = try Scenario()
    let environment = try scenario.compose(
      behaviour: ["--hold"], secondary: ["--hold"],
      extraEnvironment: ["HTTPS_PROXY": "http://\(canary)@proxy.invalid:8080"])
    let model = environment.appModel
    await model.load()
    let folder = try scenario.folder("work-\(canary)")

    let id = try await scenario.create(
      in: environment, name: "Session \(canary)", prompt: "Fix \(canary)", folder: folder)
    #expect(await eventually { await scenario.output(id, in: environment).contains(canary) })

    // Notes, typed and saved.
    let notes = model.notes.document(for: id)
    await notes.load()
    notes.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Note \(canary)")
    notes.didChange()
    #expect(await notes.save())

    // Typed into the terminal, and echoed back.
    await scenario.type("typed \(canary)\r", into: id, in: environment)
    #expect(await eventually { await scenario.output(id, in: environment).contains("echo: typed") })

    // The agent switched with a summary that carries the name, the prompt and the notes.
    model.beginAgentSwitch(id, preselected: AgentTarget(providerID: "mock-b"))
    let sheet = try #require(model.pendingSwitch)
    #expect(await eventually { sheet.canSwitch })
    await model.confirmAgentSwitch()
    #expect(await eventually { await scenario.processIdentifier(id, in: environment) != nil })

    // An export, as the user would save it.
    model.beginDiagnosticsExport()
    let export = try #require(model.diagnosticsExport)
    #expect(await eventually { export.state == .ready })
    let archiveURL = URL(fileURLWithPath: scenario.root).appendingPathComponent("export.zip")
    export.save(to: archiveURL)
    #expect(export.state == .saved(fileName: "export.zip"))
    model.endDiagnosticsExport()

    // Closed, archived, and the application quit: every event of the run is on disk.
    await model.close(id)
    await model.archive(id)
    await environment.shutdown(keepingAgentsRunning: false)
    #expect(await eventually { ProcessTree.snapshot(under: scenario.root).isEmpty })
    // The host writes its last lines as it leaves, once idle.
    try await Task.sleep(for: .seconds(1))

    let application = try Data(contentsOf: scenario.logs.applicationLog)
    let host = (try? Data(contentsOf: scenario.logs.hostLog)) ?? Data()
    let archive = try Data(contentsOf: archiveURL)
    let files = export.files

    // Not vacuous: the logs and the export did record this run.
    let applicationText = String(decoding: application, as: UTF8.self)
    #expect(applicationText.contains("\"session.launched\""))
    #expect(applicationText.contains("\"session.agentSwitched\""))
    #expect(String(decoding: host, as: UTF8.self).contains("\"host.sessionStarted\""))
    #expect(files.contains { $0.name == "logs/app.jsonl" && !$0.contents.isEmpty })

    let forbidden = Self.forms(of: canary)
    for (name, data) in [("app.jsonl", application), ("host.jsonl", host), ("export.zip", archive)]
      + files.map({ ("export/\($0.name)", $0.contents) })
    {
      let text = String(decoding: data, as: UTF8.self)
      for form in forbidden {
        #expect(!text.contains(form), "\(name) carries the canary as \(form.prefix(24))…")
        #expect(data.range(of: Data(form.utf8)) == nil, "\(name) carries the canary's bytes")
      }
    }
    // The folder is named nowhere in clear, even though it was worked in.
    for (name, data) in [("app.jsonl", application), ("host.jsonl", host)] {
      #expect(
        !String(decoding: data, as: UTF8.self).contains((folder as NSString).lastPathComponent),
        "\(name) names the folder")
    }
    await scenario.tearDown()
  }

  /// The canary as it could leak: in clear, and in base64 at each of the three alignments a
  /// longer text can put it in.
  static func forms(of canary: String) -> [String] {
    var forms = [canary, canary.lowercased()]
    for prefix in ["", "x", "xy"] {
      let encoded = Data((prefix + canary).utf8).base64EncodedString()
      // Only the part that depends on the canary alone, away from the edges.
      let start = encoded.index(encoded.startIndex, offsetBy: 4)
      let end = encoded.index(encoded.endIndex, offsetBy: -4)
      forms.append(String(encoded[start..<end]))
    }
    return forms
  }
}

@MainActor
@Suite("Multi-repository report", .timeLimit(.minutes(1)))
struct RepositoryScenarioTests {
  private struct Transcript: SessionTranscriptReading {
    let activity: TranscriptActivity
    func activity(for session: WorkSession) async -> TranscriptActivity? { activity }
  }

  @discardableResult
  private func git(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
    let result = try await ProcessGitCommandRunner().run(arguments, in: directory)
    #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.errorOutput)")
    return result
  }

  private func repository(_ path: String) async throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try await git(["init", "-q", "-b", "main"], in: path)
    try await git(["config", "user.name", "Scenario"], in: path)
    try await git(["config", "user.email", "scenario@example.com"], in: path)
    try await git(["config", "commit.gpgsign", "false"], in: path)
    try Data("start\n".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("README"))
    try await git(["add", "README"], in: path)
    try await git(["commit", "-q", "-m", "Start"], in: path)
  }

  @Test("Two repositories and a worktree: each change is reported in the repository it is in")
  func multiRepository() async throws {
    let scenario = try Scenario()
    defer { try? FileManager.default.removeItem(atPath: scenario.root) }
    let first = (scenario.root as NSString).appendingPathComponent("first")
    let second = (scenario.root as NSString).appendingPathComponent("second")
    let worktree = (scenario.root as NSString).appendingPathComponent("first-feature")
    try await repository(first)
    try await repository(second)
    try await git(["worktree", "add", "-q", "-b", "feature", worktree], in: first)

    let session = WorkSession(
      name: "Across repositories", status: .active,
      createdAt: Date().addingTimeInterval(-60),
      repositories: [RepositoryContext(path: first)])
    for (folder, file) in [(first, "a.txt"), (second, "b.txt"), (worktree, "w.txt")] {
      try Data("\(file)\n".utf8).write(
        to: URL(fileURLWithPath: folder).appendingPathComponent(file))
    }
    let reader = ReadSessionBranchReport(
      reader: GitActivityReader(),
      transcripts: Transcript(
        activity: TranscriptActivity(
          editedPaths: [
            (second as NSString).appendingPathComponent("b.txt"),
            (worktree as NSString).appendingPathComponent("w.txt"),
          ])))

    let report = await reader(for: session)

    let roots = Set(report.repositories.map { CanonicalPath.of($0.path) })
    #expect(roots == Set([first, second, worktree].map(CanonicalPath.of)))
    let status = GitStatusReader()
    for (folder, file) in [(first, "a.txt"), (second, "b.txt"), (worktree, "w.txt")] {
      let read = try await status.status(atPath: folder, limit: 100).get()
      #expect(read.entries.map(\.path) == [file], "\(folder)")
    }
  }
}
