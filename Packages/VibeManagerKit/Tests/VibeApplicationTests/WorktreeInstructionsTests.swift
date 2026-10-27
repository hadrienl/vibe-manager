import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Worktree instructions (#432)")
struct WorktreeInstructionsTests {
  private let agent = AgentProviderID("claude-code")
  private let day = Date(timeIntervalSince1970: 1_793_000_000)

  @Test("A session is given the path with what Vibe Manager knows resolved")
  func session() throws {
    let session = WorkSession(
      name: "Update banner", repositories: [RepositoryContext(path: "/nowhere/vibe")])
    let text = try #require(
      WorktreeInstructions.text(
        for: session, agent: agent,
        settings: WorktreeLocationSettings(
          general: WorktreeLocation(template: "{repo}/.wt/{session}-{branch}-{agent}")), now: day))
    #expect(text.contains("`/nowhere/vibe/.wt/update-banner-{branch}-claude-code`"))
    #expect(text.contains(".git/info/exclude"))
  }

  @Test("A coordinator gets the variables to fill, and the exceptions")
  func coordinator() throws {
    let session = WorkSession(
      name: "V2", repositories: [RepositoryContext(path: "/nowhere/vibe")],
      coordination: .coordinator)
    let text = try #require(
      WorktreeInstructions.text(
        for: session, agent: agent,
        settings: WorktreeLocationSettings(
          general: WorktreeLocation(template: "~/W/{project}/{branch}"),
          exceptions: ["/nowhere/api": WorktreeLocation(template: "/x/{ticket}")])))
    #expect(text.contains("`~/W/{project}/{branch}`"))
    #expect(text.contains("- /nowhere/api: `/x/{ticket}`"))
    #expect(!text.contains(".git/info/exclude"))
  }

  @Test("An empty path says nothing")
  func empty() {
    let settings = WorktreeLocationSettings(general: WorktreeLocation(template: ""))
    #expect(
      WorktreeInstructions.text(for: WorkSession(name: "x"), agent: agent, settings: settings)
        == nil)
  }

  @Test("A worktree's main repository is read from its .git file")
  func mainRepository() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "gitdir: /src/vibe/.git/worktrees/feat-1\n".write(
      to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(WorktreeInstructions.mainRepository(of: folder.path) == "/src/vibe")
    #expect(WorktreeInstructions.mainRepository(of: "/nowhere/vibe") == "/nowhere/vibe")
    let nested = folder.appendingPathComponent("wt/feat-2", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "gitdir: ../../repo/.git/worktrees/feat-2\n".write(
      to: nested.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(
      WorktreeInstructions.mainRepository(of: nested.path)
        == (folder.appendingPathComponent("repo").path as NSString).standardizingPath)
  }
}
