import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeGit

@Suite("Reading what git prints")
struct GitParsingTests {
  @Test("Every kind of worktree record is read from the NUL-separated listing")
  func worktreeRecordsAreParsed() {
    let fields = [
      "worktree /repos/main", "HEAD 1111111111111111111111111111111111111111",
      "branch refs/heads/main", "",
      "worktree /repos/detached", "HEAD 2222222222222222222222222222222222222222", "detached", "",
      "worktree /repos/locked", "HEAD 3333333333333333333333333333333333333333",
      "branch refs/heads/vibe/locked", "locked on an external disk", "",
      "worktree /repos/gone", "HEAD 4444444444444444444444444444444444444444",
      "branch refs/heads/vibe/gone", "prunable gitdir file points to non-existent location", "",
      "worktree /repos/bare.git", "bare", "",
    ]
    let data = Data(fields.joined(separator: "\0").utf8)

    let records = GitRepositoryInspector.parseWorktrees(data)

    #expect(records.count == 5)
    #expect(records[0].branchName == "main")
    #expect(records[0].headRevision == String(repeating: "1", count: 40))
    #expect(records[1].branchName == nil)
    #expect(records[2].isLocked)
    #expect(records[2].lockReason == "on an external disk")
    #expect(records[2].branchName == "vibe/locked")
    #expect(records[3].isPrunable)
    #expect(!records[3].isLocked)
    #expect(records[4].isBare)
  }

  @Test("A lock without a reason is still a lock")
  func lockWithoutReason() {
    let data = Data(
      ["worktree /repos/a", "HEAD abc", "detached", "locked", ""].joined(separator: "\0").utf8)

    let record = GitRepositoryInspector.parseWorktrees(data).first

    #expect(record?.isLocked == true)
    #expect(record?.lockReason == nil)
  }

  @Test(
    "Every derived slug makes a branch git accepts",
    arguments: [
      "Refonte — facturation (V2)",
      "Réparer l'œil de Ægir ß",
      "🚀🔥 Ship it 🎉",
      "!!!???...",
      String(repeating: "abcdefghij ", count: 20),
      "",
      "...",
      ".lock",
      "feature.lock",
      "修复登录问题",
      "--force",
      "a/b\\c:d?e*f[g]h~i^j",
    ]
  )
  func derivedSlugsPassCheckRefFormat(title: String) async throws {
    let slug = SessionSlug.derived(fromTitle: title, fallback: { "a1b2c3" })

    let result = try await ProcessGitCommandRunner().run(
      ["check-ref-format", "--branch", slug.branchName],
      in: FileManager.default.temporaryDirectory.path
    )

    #expect(result.succeeded, "\(slug.branchName) was refused: \(result.errorOutput)")
    #expect(slug.rawValue.count <= SessionSlug.derivedLength + "session-".count)
  }
}
