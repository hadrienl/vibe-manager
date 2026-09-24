import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private let root = "/work/api"

private func report(
  _ path: String = root, name: String = "api", branch: String? = "main",
  change: BranchChange? = nil, isUnreadable: Bool = false
) -> RepositoryBranchReport {
  RepositoryBranchReport(
    path: path, name: name, involvement: .attached, checkedOutBranch: branch, change: change,
    isDirty: false, isUnreadable: isUnreadable)
}

private func state(
  _ entries: [(WorkingTreeEntry, Bool)],
  session: SessionID = SessionID(),
  path: String = root,
  branch: BranchStatus = BranchStatus(headRevision: "abc1234def", branchName: "main"),
  operation: RepositoryOperation? = nil,
  phase: RepositoryStatusState.Phase = .fresh,
  isTruncated: Bool = false,
  committed: [(CommittedFile, Bool)] = [],
  commitCount: Int = 7,
  committedTotal: Int? = nil
) -> RepositoryStatusState {
  var counts = WorkingTreeCounts()
  for (entry, _) in entries {
    switch entry.kind {
    case .untracked, .untrackedDirectory: counts.untracked += 1
    case .conflicted: counts.conflicted += 1
    default:
      if entry.isStaged { counts.staged += 1 }
      if entry.isUnstaged { counts.unstaged += 1 }
    }
  }
  let status = WorkingTreeStatus(
    repositoryPath: path, branch: branch, operation: operation, entries: entries.map(\.0),
    counts: counts, isTruncated: isTruncated,
    committed: committed.isEmpty
      ? nil
      : BranchCommits(
        base: "origin/main", mergeBase: "1a2b3c4d5e6f", commitCount: commitCount,
        files: committed.map(\.0), totalCount: committedTotal ?? committed.count),
    observedAt: Date(timeIntervalSince1970: 1_000))
  return RepositoryStatusState(
    key: RepositoryStatusKey(sessionID: session, repositoryPath: path), lastValid: status,
    entries: entries.map { AttributedEntry(entry: $0.0, touchedByAgent: $0.1) },
    committed: committed.map { AttributedCommittedFile(file: $0.0, touchedByAgent: $0.1) },
    phase: phase, sharedWith: [])
}

private func tracked(_ path: String, _ staged: FileChange?, _ unstaged: FileChange?)
  -> WorkingTreeEntry
{
  WorkingTreeEntry(path: path, kind: .tracked(staged: staged, unstaged: unstaged))
}

@Suite("What a repository's group shows")
struct RepositoryGroupPresentationTests {
  private func rows(_ group: RepositoryGroupPresentation, _ column: ChangeColumn) -> [FileRow] {
    group.sections.first { $0.column == column }?.rows ?? []
  }

  @Test("Each kind of change lands in its list, with its letter; `MM` is in both")
  func sections() {
    let group = RepositoryGroupPresentation(
      report: report(),
      state: state([
        (tracked("Sources/Both.swift", .modified, .modified), true),
        (tracked("new.txt", .added, nil), true),
        (tracked("gone.txt", nil, .deleted), false),
        (tracked("renamed.swift", .renamed(from: "old.swift", similarity: 92), nil), true),
        (WorkingTreeEntry(path: "c.txt", kind: .conflicted(.bothModified)), true),
        (WorkingTreeEntry(path: "loose.txt", kind: .untracked), false),
        (WorkingTreeEntry(path: "Generated/", kind: .untrackedDirectory), true),
        (
          WorkingTreeEntry(
            path: "vendor/lib",
            kind: .submodule(staged: nil, unstaged: .modified, [.trackedChanges])),
          true
        ),
      ]))

    #expect(group.sections.map(\.column) == [.conflicts, .staged, .unstaged, .untracked])
    #expect(rows(group, .conflicts).map(\.letter) == ["UU"])
    #expect(rows(group, .staged).map(\.letter) == ["M", "A", "R"])
    #expect(rows(group, .unstaged).map(\.letter) == ["M", "D", "M"])
    #expect(rows(group, .untracked).map(\.letter) == ["?", "?"])

    let both = rows(group, .staged)[0]
    #expect(both.name == "Both.swift")
    #expect(both.directory == "Sources")
    #expect(both.id != rows(group, .unstaged)[0].id)
    #expect(both.id.path == rows(group, .unstaged)[0].id.path)

    let renamed = rows(group, .staged)[2]
    #expect(renamed.renamedFrom == "old.swift")
    #expect(renamed.change == "renamed, 92 % similar")

    let gone = rows(group, .unstaged)[1]
    #expect(!gone.isOnDisk)
    #expect(!gone.isAttributed)
    #expect(
      gone.accessibilityLabel == "gone.txt, unstaged: deleted, not in this session's transcript")

    let folder = rows(group, .untracked)[1]
    #expect(folder.isDirectory)
    #expect(folder.name == "Generated/")

    let submodule = rows(group, .unstaged)[2]
    #expect(submodule.isSubmodule)
    #expect(submodule.change == "submodule, modified content")
    #expect(group.changeCount == 8)
    #expect(group.isExpandedByDefault)
  }

  @Test("A clean tree on a branch that committed lists its files, and no longer says No changes")
  func committed() {
    let group = RepositoryGroupPresentation(
      report: report(branch: "feat/x"),
      state: state(
        [],
        committed: [
          (CommittedFile(path: "Sources/App.swift", change: .modified), true),
          (
            CommittedFile(path: "new.swift", change: .renamed(from: "old.swift", similarity: 90)),
            true
          ),
          (CommittedFile(path: "gone.txt", change: .deleted), false),
        ]))

    #expect(group.summary == "Working tree clean — 3 files committed since origin/main")
    #expect(group.sections.map(\.column) == [.committed])
    #expect(rows(group, .committed).map(\.letter) == ["M", "R", "D"])
    #expect(rows(group, .committed)[1].renamedFrom == "old.swift")
    #expect(!rows(group, .committed)[2].isOnDisk)
    #expect(
      rows(group, .committed)[2].accessibilityLabel
        == "gone.txt, committed: deleted, not in this session's transcript")
    #expect(group.sections[0].help == "7 commits since origin/main (merge base 1a2b3c4)")
    // The count is what is not committed yet; the group opens all the same.
    #expect(group.changeCount == 0)
    #expect(!group.hasChanges)
    #expect(group.committedCount == 3)
    #expect(group.isExpandedByDefault)
  }

  @Test("Changes and commits are both said; past the limit, the total is kept")
  func committedBesideChanges() {
    let group = RepositoryGroupPresentation(
      report: report(),
      state: state(
        [(tracked("a.swift", nil, .modified), true)],
        committed: [(CommittedFile(path: "b.swift", change: .added), true)],
        commitCount: 1, committedTotal: 6_000))

    #expect(group.summary == "1 unstaged · 6000 files committed since origin/main")
    #expect(group.sections.map(\.column) == [.unstaged, .committed])
    #expect(group.sections[1].totalCount == 6_000)
    #expect(group.sections[1].help == "1 commit since origin/main (merge base 1a2b3c4)")
  }

  @Test("A name macOS wrote decomposed reads composed, and keeps Git's spelling as its key")
  func unicode() {
    let decomposed = "Cafe\u{301}/re\u{301}sume\u{301}.md"
    let group = RepositoryGroupPresentation(
      report: report(), state: state([(tracked(decomposed, nil, .modified), true)]))
    let row = group.sections[0].rows[0]

    #expect(row.name == "résumé.md")
    #expect(row.name.unicodeScalars.count == "résumé.md".unicodeScalars.count)
    #expect(row.directory == "Café")
    #expect(row.id.path == decomposed)
  }

  @Test("A name with a new line stays one row")
  func newLine() {
    let group = RepositoryGroupPresentation(
      report: report(), state: state([(tracked("odd\nname.txt", nil, .modified), true)]))
    #expect(group.sections[0].rows.count == 1)
    #expect(group.sections[0].rows[0].name == "odd\nname.txt")
  }

  @Test("Branch, distance from upstream, detached HEAD and a repository without commits")
  func branches() {
    let tracking = RepositoryGroupPresentation(
      report: report(),
      state: state(
        [],
        branch: BranchStatus(
          headRevision: "abc", branchName: "feat/x", upstream: "origin/feat/x", ahead: 2,
          behind: 1)))
    #expect(tracking.branch == .named("feat/x"))
    #expect(tracking.arrows == "↑2 ↓1")
    #expect(tracking.distance == "2 ahead, 1 behind origin/feat/x")
    #expect(!tracking.isExpandedByDefault)
    #expect(tracking.summary == "No changes")

    let detached = RepositoryGroupPresentation(
      report: report(), state: state([], branch: BranchStatus(headRevision: "1a2b3c4d5e")))
    #expect(detached.branch.text == "detached at 1a2b3c4")
    #expect(detached.arrows == nil)

    let unborn = RepositoryGroupPresentation(
      report: report(), state: state([], branch: BranchStatus(branchName: "main")))
    #expect(unborn.branch.text == "main, no commits yet")

    let worktree = RepositoryGroupPresentation(
      report: report(
        name: "api · worktree oauth",
        change: BranchChange(name: "main", kind: .created, commitCount: 3)),
      state: nil)
    #expect(worktree.title == "api")
    #expect(worktree.worktree == "worktree oauth")
    #expect(worktree.pills.map(\.label) == ["new", "+3"])
    #expect(worktree.isLoading)
    #expect(worktree.branch == .named("main"))
  }

  @Test("A failure keeps the last list, dated, with the action that helps")
  func failures() {
    let missing = RepositoryGroupPresentation(
      report: report(),
      state: state(
        [(tracked("a.txt", nil, .modified), true)],
        phase: .failed(.missing(path: root), since: Date())))
    #expect(missing.banner?.action == .revealParent("/work"))
    #expect(missing.sections.count == 1)
    #expect(missing.asOf == Date(timeIntervalSince1970: 1_000))
    #expect(missing.isExpandedByDefault)

    let closed = RepositoryGroupPresentation(
      report: report(),
      state: state([], phase: .failed(.permissionDenied(path: root), since: Date())))
    #expect(closed.banner?.action == .openPrivacySettings)
    #expect(closed.isExpandedByDefault)

    let unsafe = RepositoryGroupPresentation(
      report: report(),
      state: state([], phase: .failed(.unsafeRepository(path: root), since: Date())))
    #expect(unsafe.banner?.command == "git config --global --add safe.directory /work/api")
    #expect(unsafe.banner?.action == .refresh)

    let unreadable = RepositoryGroupPresentation(report: report(isUnreadable: true), state: nil)
    #expect(unreadable.pills.map(\.label) == ["unreadable"])
    #expect(unreadable.branch == .unknown)
  }

  @Test("Git missing everywhere is said once; every repository clean is said once")
  func pane() {
    let session = WorkSession(name: "S", repositories: [RepositoryContext(path: "/work")])
    let reports = [report("/work/api", name: "api"), report("/work/web", name: "web")]
    let branchReport = SessionBranchReport(
      sessionID: session.id, repositories: reports, readAt: Date())

    let missingGit = reports.map {
      RepositoryGroupPresentation(
        report: $0,
        state: state(
          [], path: $0.path,
          phase: .failed(.gitUnavailable(.commandLineToolsMissing), since: Date())))
    }
    let failing = GitPanePresentation(groups: missingGit, plainFolders: [])
    #expect(failing.sharedIssue?.command == "xcode-select --install")
    #expect(failing.allClean == nil)
    // A folder of repositories is not one itself, and is said to be so.
    let roots = branchReport.repositories.map(\.path)
    #expect(
      GitPanePresentation.plainFolders(session.repositories.map(\.path), roots: roots) == ["/work"])

    let clean = reports.map {
      RepositoryGroupPresentation(report: $0, state: state([], path: $0.path))
    }
    let pane = GitPanePresentation(groups: clean, plainFolders: [])
    #expect(pane.allClean == "Nothing to commit in 2 repositories")
    #expect(pane.sharedIssue == nil)

    let inside = WorkSession(
      name: "S", repositories: [RepositoryContext(path: "/work/api/Sources")])
    #expect(
      GitPanePresentation.plainFolders(inside.repositories.map(\.path), roots: roots).isEmpty)
  }
}

@MainActor
@Suite("The Git pane's screen state")
struct GitInspectorModelTests {
  private let session = SessionID()

  private func makeModel(
    opener: FakeOpener = FakeOpener(), editor: EditorChoice? = nil,
    list: GitInspectorModel.ListUntracked? = nil
  ) -> GitInspectorModel {
    GitInspectorModel(
      listUntracked: list, opener: opener,
      editor: editor)
  }

  private func row(_ column: ChangeColumn, _ path: String, child: String? = nil)
    -> GitInspectorRowID
  {
    GitInspectorRowID(repositoryPath: root, column: column, path: path, child: child)
  }

  @Test("A repository folded by hand stays folded when its files change; a default one follows")
  func expansion() {
    let git = makeModel()
    let dirty = RepositoryGroupPresentation(
      report: report(), state: state([(tracked("a", nil, .modified), true)], session: session))
    let clean = RepositoryGroupPresentation(report: report(), state: state([], session: session))

    #expect(git.isExpanded(dirty, in: session))
    #expect(!git.isExpanded(clean, in: session))

    git.setExpanded(root, false, in: session)
    #expect(!git.isExpanded(dirty, in: session))
    // Another session keeps its own.
    #expect(git.isExpanded(dirty, in: SessionID()))
  }

  @Test("A long untracked list starts folded; Show More and Show All are kept")
  func sectionsAndLimits() {
    let git = makeModel()
    let many = (0..<60).map { (WorkingTreeEntry(path: "f\($0)", kind: .untracked), true) }
    let group = RepositoryGroupPresentation(report: report(), state: state(many))
    let untracked = group.sections[0]
    #expect(!git.isExpanded(untracked, in: session))

    #expect(git.rowLimit(untracked.id, in: session) == 200)
    git.showMore(untracked.id, in: session)
    #expect(git.rowLimit(untracked.id, in: session) == 400)
    git.showAll(untracked.id, in: session)
    #expect(git.rowLimit(untracked.id, in: session) == .max)
  }

  @Test("The selection follows its file when it is staged, and is dropped when it is committed")
  func selectionFollowsTheFile() {
    let git = makeModel()
    git.select(row(.unstaged, "a.swift"), in: session)

    git.statesChanged([state([(tracked("a.swift", nil, .modified), true)], session: session)])
    #expect(git.selection(in: session) == row(.unstaged, "a.swift"))

    git.statesChanged([state([(tracked("a.swift", .modified, nil), true)], session: session)])
    #expect(git.selection(in: session) == row(.staged, "a.swift"))

    // Staged and changed again: still there, in the list it was in.
    git.statesChanged([state([(tracked("a.swift", .modified, .modified), true)], session: session)])
    #expect(git.selection(in: session) == row(.staged, "a.swift"))

    git.statesChanged([state([], session: session)])
    #expect(git.selection(in: session) == nil)
  }

  @Test("A file selected when it is committed follows into Committed, and leaves with it")
  func selectionFollowsIntoCommitted() {
    let git = makeModel()
    git.statesChanged([state([(tracked("a.swift", .modified, nil), true)], session: session)])
    git.select(row(.staged, "a.swift"), in: session)

    let committed = [(CommittedFile(path: "a.swift", change: .modified), true)]
    git.statesChanged([state([], session: session, committed: committed)])
    #expect(git.selection(in: session) == row(.committed, "a.swift"))

    git.statesChanged([state([], session: session)])
    #expect(git.selection(in: session) == nil)
  }

  @Test("A long committed list starts folded")
  func longCommittedList() {
    let git = makeModel()
    let many = (0..<60).map { (CommittedFile(path: "f\($0)", change: .added), true) }
    let few = [(CommittedFile(path: "f", change: .added), true)]
    let long = RepositoryGroupPresentation(report: report(), state: state([], committed: many))
    let short = RepositoryGroupPresentation(report: report(), state: state([], committed: few))
    #expect(!git.isExpanded(long.sections[0], in: session))
    #expect(git.isExpanded(short.sections[0], in: session))
  }

  @Test("Another repository's state leaves the selection alone")
  func otherRepository() {
    let git = makeModel()
    git.statesChanged([state([(tracked("a.swift", nil, .modified), true)], session: session)])
    git.select(row(.unstaged, "a.swift"), in: session)
    git.statesChanged([state([], session: session, path: "/work/web")])
    #expect(git.selection(in: session) == row(.unstaged, "a.swift"))
  }

  @Test("An untracked folder is read when unfolded, again when its repository moves, never folded")
  func untrackedFolders() async {
    let reads = ReadCounter()
    let git = makeModel(list: { directory, _ in
      await reads.increment()
      return .success(
        UntrackedListing(directory: directory, paths: [directory + "a.swift"], totalCount: 1))
    })
    let folder = row(.untracked, "Generated/")
    let withFolder = state(
      [(WorkingTreeEntry(path: "Generated/", kind: .untrackedDirectory), true)], session: session)
    git.statesChanged([withFolder])
    #expect(await reads.value == 0)

    git.setExpanded(directory: folder, true, in: session)
    #expect(await poll { git.listing(of: folder, in: session) != .loading })
    #expect(
      git.listing(of: folder, in: session)
        == .loaded(
          UntrackedListing(directory: "Generated/", paths: ["Generated/a.swift"], totalCount: 1)))
    #expect(await reads.value == 1)

    git.statesChanged([withFolder])
    #expect(await poll { await reads.value == 2 })

    // The folder was committed: forgotten, and not read.
    git.statesChanged([state([], session: session)])
    #expect(!git.isExpanded(directory: folder, in: session))
    git.setExpanded(directory: folder, false, in: session)
    git.statesChanged([withFolder])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await reads.value == 2)
  }

  @Test("One listing at a time per folder; what the folder became meanwhile is read once more")
  func listingsDoNotPileUp() async {
    let gate = ListingGate()
    let git = makeModel(list: { directory, _ in
      let round = await gate.enter()
      return .success(
        UntrackedListing(directory: directory, paths: ["\(directory)v\(round)"], totalCount: 1))
    })
    let folder = row(.untracked, "node_modules/")
    let withFolder = state(
      [(WorkingTreeEntry(path: "node_modules/", kind: .untrackedDirectory), true)],
      session: session)
    git.statesChanged([withFolder])
    git.setExpanded(directory: folder, true, in: session)
    #expect(await poll { await gate.entered == 1 })

    // Three states land while the first reading runs: they ask for one more, not three.
    git.statesChanged([withFolder])
    git.statesChanged([withFolder])
    git.statesChanged([withFolder])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await gate.entered == 1)

    await gate.release()
    #expect(await poll { await gate.entered == 2 })
    // The first answer was already old: it is not shown.
    #expect(git.listing(of: folder, in: session) == .loading)
    await gate.release()
    #expect(
      await poll {
        git.listing(of: folder, in: session)
          == .loaded(
            UntrackedListing(directory: "node_modules/", paths: ["node_modules/v2"], totalCount: 1))
      })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await gate.entered == 2)
  }

  @Test("Folding away the selected row drops the selection")
  func foldingDropsTheSelection() {
    let git = makeModel()
    git.select(row(.unstaged, "a.swift"), in: session)
    git.setExpanded(GitSectionID(repositoryPath: root, column: .staged), false, in: session)
    #expect(git.selection(in: session) == row(.unstaged, "a.swift"))
    git.setExpanded(GitSectionID(repositoryPath: root, column: .unstaged), false, in: session)
    #expect(git.selection(in: session) == nil)

    git.select(row(.unstaged, "a.swift"), in: session)
    git.setExpanded(root, false, in: session)
    #expect(git.selection(in: session) == nil)

    let folder = row(.untracked, "Generated/")
    git.setExpanded(directory: folder, true, in: session)
    git.select(row(.untracked, "Generated/", child: "Generated/a.swift"), in: session)
    git.setExpanded(directory: folder, false, in: session)
    #expect(git.selection(in: session) == nil)
  }

  @Test("A selection followed past what a list shows opens the list far enough to show it")
  func followedSelectionStaysVisible() {
    let git = makeModel()
    let others = (0..<450).map { (tracked("f\($0)", .modified, nil), true) }
    git.select(row(.unstaged, "z.swift"), in: session)
    git.statesChanged([state([(tracked("z.swift", nil, .modified), true)], session: session)])
    git.setExpanded(GitSectionID(repositoryPath: root, column: .staged), false, in: session)

    git.statesChanged([
      state(others + [(tracked("z.swift", .modified, nil), true)], session: session)
    ])

    let staged = GitSectionID(repositoryPath: root, column: .staged)
    #expect(git.selection(in: session) == row(.staged, "z.swift"))
    #expect(git.rowLimit(staged, in: session) == 600)
    let section = RepositoryGroupPresentation(
      report: report(), state: state(others + [(tracked("z.swift", .modified, nil), true)])
    ).sections[0]
    #expect(git.isExpanded(section, in: session))
  }

  @Test("A path Git lists twice keeps the selection in the list the user picked it in")
  func pathListedTwice() {
    let git = makeModel()
    git.select(row(.untracked, "foo"), in: session)

    // `git rm --cached foo`: a staged deletion, and the file kept on disk, untracked.
    git.statesChanged([
      state(
        [
          (tracked("foo", .deleted, nil), true),
          (WorkingTreeEntry(path: "foo", kind: .untracked), true),
        ], session: session)
    ])
    #expect(git.selection(in: session) == row(.untracked, "foo"))
  }

  @Test("A selection followed into a list folded by default opens it")
  func followedIntoAFoldedList() {
    let git = makeModel()
    let many = (0..<60).map { (WorkingTreeEntry(path: "f\($0)", kind: .untracked), true) }
    git.select(row(.staged, "z.swift"), in: session)

    // `git reset z.swift` on an added file, beside a long untracked list.
    git.statesChanged([
      state(many + [(WorkingTreeEntry(path: "z.swift", kind: .untracked), true)], session: session)
    ])

    #expect(git.selection(in: session) == row(.untracked, "z.swift"))
    let untracked = RepositoryGroupPresentation(
      report: report(),
      state: state(many + [(WorkingTreeEntry(path: "z.swift", kind: .untracked), true)])
    ).sections[0]
    #expect(git.isExpanded(untracked, in: session))
  }

  @Test("A folder is revealed, never opened in the editor; the default application is on demand")
  func foldersAreRevealed() async {
    let opener = FakeOpener()
    opener.existing = [root + "/Generated", root + "/a.swift"]
    opener.installed = ["dev.zed.Zed": "Zed"]
    let git = makeModel(opener: opener, editor: .application(bundleIdentifier: "dev.zed.Zed"))

    await git.activate(row(.untracked, "Generated/"))
    #expect(opener.revealed == [root + "/Generated"])
    #expect(opener.opened.isEmpty)

    await git.openWithDefaultApplication(row(.unstaged, "a.swift"))
    #expect(opener.opened == [root + "/a.swift"])
    #expect(opener.editors == [.defaultApplication])
  }

  @Test("The editor chosen in Settings reaches the menus at once")
  func editorIsObserved() {
    let opener = FakeOpener()
    opener.installed = ["dev.zed.Zed": "Zed"]
    let git = makeModel(opener: opener)
    #expect(git.editorName == nil)
    git.editor = .application(bundleIdentifier: "dev.zed.Zed")
    #expect(git.editorName == "Zed")
  }

  @Test("Without an editor Return reveals; with one it opens; an editor gone reveals and says so")
  func activation() async {
    let opener = FakeOpener()
    opener.existing = [root + "/a.swift"]
    let target = row(.unstaged, "a.swift")

    await makeModel(opener: opener).activate(target)
    #expect(opener.revealed == [root + "/a.swift"])
    #expect(opener.opened.isEmpty)

    let zed = EditorChoice.application(bundleIdentifier: "dev.zed.Zed")
    opener.installed = ["dev.zed.Zed": "Zed"]
    let withEditor = makeModel(opener: opener, editor: zed)
    await withEditor.activate(target)
    #expect(opener.opened == [root + "/a.swift"])
    #expect(withEditor.editorName == "Zed")

    opener.installed = [:]
    let gone = makeModel(opener: opener, editor: zed)
    await gone.activate(target)
    #expect(opener.revealed.last == root + "/a.swift")
    #expect(gone.notice?.contains("no longer installed") == true)
  }

  @Test("A deleted file reveals the closest folder that is still there")
  func deletedFile() {
    let opener = FakeOpener()
    opener.existing = [root + "/Sources"]
    makeModel(opener: opener).reveal(row(.unstaged, "Sources/Gone/Old.swift"))
    #expect(opener.revealed == [root + "/Sources"])
  }

  @Test("A path that would lead outside the repository is refused")
  func escapingPath() {
    #expect(GitInspectorModel.url(of: row(.unstaged, "../etc/passwd")) == nil)
    #expect(GitInspectorModel.url(of: row(.unstaged, "a/../../x")) == nil)
    #expect(GitInspectorModel.url(of: row(.unstaged, "/etc/passwd")) == nil)
    #expect(GitInspectorModel.url(of: row(.unstaged, "a/../b.txt"))?.path == root + "/b.txt")
    #expect(
      GitInspectorModel.url(of: row(.untracked, "Generated/", child: "Generated/x.swift"))?.path
        == root + "/Generated/x.swift")
  }

  @Test("Copy gives the absolute path, or the one relative to the repository")
  func copying() {
    let opener = FakeOpener()
    let git = makeModel(opener: opener)
    git.copyPath(row(.staged, "Sources/A.swift"), relative: false)
    git.copyPath(row(.staged, "Sources/A.swift"), relative: true)
    #expect(opener.copied == [root + "/Sources/A.swift", "Sources/A.swift"])
  }

  @Test("A presentation is rebuilt only when what it is made from changes")
  func cachedPresentation() {
    let git = makeModel()
    let current = state([(tracked("a", nil, .modified), true)], session: session)
    let first = git.group(for: report(), state: current, sessionNames: [:])
    #expect(git.group(for: report(), state: current, sessionNames: [:]) == first)
    let next = state([(tracked("b", nil, .modified), true)], session: session)
    #expect(
      git.group(for: report(), state: next, sessionNames: [:]).sections[0].rows[0].name == "b")
  }

  @Test("Five thousand entries a second for ten seconds never hold the main actor 50 ms")
  func largeLists() async {
    let git = makeModel()
    let entries = (0..<5_000).map {
      (
        tracked(
          "Sources/Module\($0 % 50)/File\($0).swift", $0.isMultiple(of: 2) ? .modified : nil,
          .modified), true
      )
    }
    git.select(row(.unstaged, "Sources/Module7/File4007.swift"), in: session)
    var worst: Duration = .zero
    let clock = ContinuousClock()
    for round in 0..<10 {
      let started = clock.now
      let current = state(Array(entries.dropFirst(round)), session: session)
      git.statesChanged([current])
      _ = git.group(for: report(), state: current, sessionNames: [:])
      worst = max(worst, clock.now - started)
    }
    // The 50 ms hold on a Mac. The CI runner, virtualised and older in its compiler, runs this
    // about 25 times slower: there the bound only catches a presentation no longer cached. A
    // second was too close — a busy runner has reached 1.06 s — so it is given three.
    let budget: Duration =
      ProcessInfo.processInfo.environment["CI"] == "true" ? .seconds(3) : .milliseconds(50)
    #expect(worst < budget)
    #expect(git.selection(in: session) == row(.unstaged, "Sources/Module7/File4007.swift"))
  }
}

@MainActor
final class FakeOpener: FileOpening {
  var existing: Set<String> = []
  var installed: [String: String] = [:]
  private(set) var revealed: [String] = []
  private(set) var opened: [String] = []
  private(set) var editors: [EditorChoice] = []
  private(set) var copied: [String] = []

  func exists(_ url: URL) -> Bool { existing.contains(url.path) }
  func reveal(_ url: URL) { revealed.append(url.path) }

  func open(_ url: URL, with editor: EditorChoice) async -> Bool {
    opened.append(url.path)
    editors.append(editor)
    return true
  }

  func name(of editor: EditorChoice) -> String? {
    switch editor {
    case .defaultApplication: return "the default application"
    case .application(let identifier): return installed[identifier]
    }
  }

  func installedEditors() -> [KnownEditor] { [] }
  func copy(_ text: String) { copied.append(text) }
}

/// Holds each listing until the test lets it go, and counts how many started.
private actor ListingGate {
  private(set) var entered = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func enter() async -> Int {
    entered += 1
    let round = entered
    await withCheckedContinuation { waiting.append($0) }
    return round
  }

  func release() {
    if !waiting.isEmpty { waiting.removeFirst().resume() }
  }
}

private actor ReadCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

@MainActor
private func poll(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async
  -> Bool
{
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}
