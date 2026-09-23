import Foundation
import Testing
import VibeDomain

@testable import VibeGit

@Suite("Reading `git status --porcelain=v2 -z`")
struct GitStatusParserTests {
  private func parse(_ records: [String], limit: Int = 5_000) -> ParsedStatus {
    GitStatusParser().parse(Data((records.joined(separator: "\0") + "\0").utf8), limit: limit)
  }

  private let modes = "N... 100644 100644 100644 aaaa bbbb"

  @Test("The branch, its upstream and how far apart they are")
  func branchHeaders() {
    let parsed = parse([
      "# branch.oid 3f2a1c9", "# branch.head feature/x", "# branch.upstream origin/feature/x",
      "# branch.ab +2 -1",
    ])
    #expect(
      parsed.branch
        == BranchStatus(
          headRevision: "3f2a1c9", branchName: "feature/x", upstream: "origin/feature/x",
          ahead: 2, behind: 1))
  }

  @Test("No commit yet, and a detached HEAD, are said as absences")
  func initialAndDetached() {
    let parsed = parse(["# branch.oid (initial)", "# branch.head (detached)"])
    #expect(parsed.branch.headRevision == nil)
    #expect(parsed.branch.branchName == nil)
    #expect(parsed.branch.ahead == nil)
  }

  @Test("Each side of a tracked file keeps its own change")
  func trackedColumns() {
    let parsed = parse([
      "1 M. \(modes) staged.txt", "1 .M \(modes) unstaged.txt", "1 MM \(modes) both.txt",
      "1 A. \(modes) added.txt", "1 D. \(modes) removed.txt", "1 .D \(modes) gone.txt",
      "1 T. \(modes) link",
    ])
    #expect(
      parsed.entries.map(\.kind) == [
        .tracked(staged: .modified, unstaged: nil),
        .tracked(staged: nil, unstaged: .modified),
        .tracked(staged: .modified, unstaged: .modified),
        .tracked(staged: .added, unstaged: nil),
        .tracked(staged: .deleted, unstaged: nil),
        .tracked(staged: nil, unstaged: .deleted),
        .tracked(staged: .typeChanged, unstaged: nil),
      ])
    #expect(parsed.counts == WorkingTreeCounts(staged: 5, unstaged: 3))
  }

  @Test("A rename carries where it came from, and how alike the two are")
  func renames() {
    let parsed = parse([
      "2 R. \(modes) R087 new name.txt", "old name.txt",
      "2 C. \(modes) C100 copy.txt", "source.txt",
      "? after.txt",
    ])
    #expect(parsed.entries.map(\.path) == ["new name.txt", "copy.txt", "after.txt"])
    #expect(
      parsed.entries[0].kind
        == .tracked(staged: .renamed(from: "old name.txt", similarity: 87), unstaged: nil))
    #expect(
      parsed.entries[1].kind
        == .tracked(staged: .copied(from: "source.txt", similarity: 100), unstaged: nil))
  }

  @Test("Conflicts, untracked files and folders, and submodules each have their case")
  func otherKinds() {
    let parsed = parse([
      "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
      "u DU N... 100644 100644 100644 100644 a b c theirs.txt",
      "? loose.txt", "? build/",
      "1 .M SCMU 160000 160000 160000 aaaa bbbb vendor/lib",
      "! ignored.txt",
    ])
    #expect(
      parsed.entries.map(\.kind) == [
        .conflicted(.bothModified), .conflicted(.deletedByUs), .untracked, .untrackedDirectory,
        .submodule(
          staged: nil, unstaged: .modified,
          [.commitChanged, .trackedChanges, .untrackedChanges]),
      ])
    #expect(parsed.counts == WorkingTreeCounts(unstaged: 1, untracked: 2, conflicted: 2))
  }

  @Test("A path is read exactly as written: spaces, quotes, tabs, new lines, accents, a dash")
  func unusualPaths() {
    let names = [
      "with space.txt", "quote\"d.txt", "tab\there.txt", "new\nline.txt", "é.txt", "-dash",
    ]
    let parsed = parse(names.map { "? \($0)" })
    #expect(parsed.entries.map(\.path) == names)
  }

  @Test("Past the limit the list stops, and the counts do not")
  func truncation() {
    let parsed = parse((0..<50).map { "? file-\($0)" }, limit: 10)
    #expect(parsed.entries.count == 10)
    #expect(parsed.counts.untracked == 50)
    #expect(parsed.isTruncated)
  }
}
