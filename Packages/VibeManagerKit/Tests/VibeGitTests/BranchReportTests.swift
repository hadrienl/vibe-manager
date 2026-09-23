import Foundation
import Testing
import VibeApplication
import VibeDomain
import VibeGit
import VibePersistence

@Suite("What the agent did to the branches, read from a real repository")
struct BranchReportTests {
  private func commit(_ message: String, in path: String) async throws {
    let file = URL(fileURLWithPath: path).appendingPathComponent("\(UUID().uuidString).txt")
    try Data(message.utf8).write(to: file)
    try await git(["add", "."], in: path)
    try await git(["commit", "-q", "-m", message], in: path)
  }

  @Test("Each session is told where it worked, on which branch, and not what another one did")
  func perSessionReport() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let folder = sandbox.path("Prisme.ai Projects")
    let workspaces = sandbox.path("Prisme.ai Projects", "prismeai-workspaces")
    let mobile = sandbox.path("Prisme.ai Projects", "Prisme.ai Mobile")
    let quiet = sandbox.path("Prisme.ai Projects", "vocalAgent")
    for path in [workspaces, mobile, quiet] { try await makeRepository(at: path) }
    // An agent's own worktree, hidden where Claude Code puts them.
    let hidden = (mobile as NSString).appendingPathComponent(".claude/worktrees/230-send")
    try await git(["worktree", "add", "-q", "-b", "230-send", hidden], in: mobile)

    // The reflog is dated to the second: the sessions start strictly after the fixtures.
    try await Task.sleep(for: .milliseconds(1_100))
    let startedAt = Date()
    try await Task.sleep(for: .milliseconds(1_100))
    try await git(["checkout", "-q", "-b", "fix/connectors"], in: workspaces)
    try await commit("Fix a connector", in: workspaces)
    try await commit("Fix another", in: hidden)
    try Data("wip".utf8).write(to: URL(fileURLWithPath: hidden).appendingPathComponent("wip"))

    func session(_ name: String) -> WorkSession {
      WorkSession(
        name: name, status: .closed, createdAt: startedAt,
        updatedAt: startedAt.addingTimeInterval(60), closedAt: startedAt.addingTimeInterval(60),
        startedAt: startedAt,
        repositories: [RepositoryContext(rootPath: folder, mode: .inPlace)])
    }
    let connectors = session("Fix all connectors")
    let phone = session("Prisme.ai mobile")
    let transcripts = TableTranscripts(activities: [
      connectors.id: TranscriptActivity(workingDirectories: [folder, workspaces, quiet]),
      phone.id: TranscriptActivity(editedPaths: [
        (hidden as NSString).appendingPathComponent("a.swift")
      ]),
    ])
    let read = ReadSessionBranchReport(reader: GitActivityReader(), transcripts: transcripts)

    let first = await read(for: connectors)
    let second = await read(for: phone)

    #expect(first.repositories.map(\.name) == ["prismeai-workspaces"])
    #expect(first.repositories.first?.checkedOutBranch == "fix/connectors")
    #expect(first.repositories.first?.change?.kind == .created)
    #expect(first.repositories.first?.change?.commitCount == 1)
    // It went into vocalAgent and changed nothing there: named, not detailed.
    #expect(first.visitedOnly == ["vocalAgent"])

    #expect(second.repositories.map(\.name) == ["Prisme.ai Mobile · worktree 230-send"])
    #expect(second.repositories.first?.checkedOutBranch == "230-send")
    #expect(second.repositories.first?.isDirty == true)
    #expect(second.repositories.first?.change?.commitCount == 1)
    #expect(!second.repositories.contains { $0.name == "prismeai-workspaces" })
  }

  @Test("The photograph is taken once, at the first start, and the branch in place is recorded")
  func baselineIsTakenOnce() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let clone = sandbox.path("web")
    try await makeRepository(at: clone)
    let session = WorkSession(
      name: "Stored before reports", repositories: [RepositoryContext(rootPath: clone)])
    let store = InMemorySessionRepository(sessions: [session])
    let capture = CaptureSessionBaseline(repository: store, reader: GitActivityReader())

    await capture(sessionID: session.id)
    let first = try #require(await store.session(id: session.id)?.repositories.first)
    try await git(["checkout", "-q", "-b", "later"], in: clone)
    try await commit("Later", in: clone)
    await capture(sessionID: session.id)
    let second = try #require(await store.session(id: session.id)?.repositories.first)

    #expect(first.branchName == "main")
    #expect(first.baseline?.branches.keys.sorted() == ["main"])
    #expect(second.baseline == first.baseline)
    #expect(second.branchName == "later")
  }
}

private struct TableTranscripts: SessionTranscriptReading {
  let activities: [SessionID: TranscriptActivity]

  func activity(for session: WorkSession) async -> TranscriptActivity? { activities[session.id] }
}
