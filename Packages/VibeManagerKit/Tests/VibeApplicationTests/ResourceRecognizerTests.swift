import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Recognizing the resources a transcript names")
struct ResourceRecognizerTests {
  private let date = Date(timeIntervalSince1970: 1_800_000_000)

  private func keys(_ text: String) -> [String] {
    ResourceRecognizer.urls(in: text, involvement: .viewed, at: date).map(\.key)
  }

  // MARK: - Shell words

  @Test(
    "A command line is cut the way a shell cuts it",
    arguments: [
      ("git push -u origin x", [["git", "push", "-u", "origin", "x"]]),
      ("cd sub && git status; ls | wc", [["cd", "sub"], ["git", "status"], ["ls"], ["wc"]]),
      (#"git commit -m "a b" -m 'c d'"#, [["git", "commit", "-m", "a b", "-m", "c d"]]),
      (#"echo a\ b"#, [["echo", "a b"]]),
      ("git status 2>&1 >/dev/null", [["git", "status"]]),
      ("ls # a comment", [["ls"]]),
    ] as [(String, [[String]])])
  func shellWords(line: String, expected: [[String]]) {
    #expect(ShellWords.commands(in: line) == expected.map { $0.map(Optional.some) })
  }

  @Test("A variable or a substitution is an unknown word, not a guess")
  func expansions() {
    #expect(
      ShellWords.commands(in: "git push origin $(git branch --show-current)")
        == [["git", "push", "origin", nil]])
    #expect(ShellWords.commands(in: #"gh pr view "$PR""#) == [["gh", "pr", "view", nil]])
  }

  // MARK: - URLs

  @Test(
    "GitHub: issues and pull requests, whatever page of them, github.com or Enterprise",
    arguments: [
      ("https://github.com/hadrienl/vibe-manager/issues/36", "github:github.com/hadrienl/vibe-manager#36"),
      ("see https://github.com/hadrienl/vibe-manager/pull/62/files.", "github:github.com/hadrienl/vibe-manager#62"),
      ("https://github.com/Owner/Repo/pull/7#issuecomment-1", "github:github.com/owner/repo#7"),
      ("http://www.github.com/o/r/issues/3?w=1", "github:github.com/o/r#3"),
      ("[PR](https://github.corp.example/o/r/pull/12)", "github:github.corp.example/o/r#12"),
      (#"{"url":"https://github.com/o/r/pull/9"}"#, "github:github.com/o/r#9"),
    ])
  func github(text: String, key: String) {
    #expect(keys(text) == [key])
  }

  @Test(
    "GitLab: issues, merge requests and work items, subgroups and self-hosted instances",
    arguments: [
      ("https://gitlab.com/gogowego-devsecops/dev/pyramide/-/merge_requests/1315", "gitlab:gitlab.com/gogowego-devsecops/dev/pyramide#mr/1315"),
      ("https://gitlab.com/g/p/-/issues/5#note_12", "gitlab:gitlab.com/g/p#issue/5"),
      ("https://gitlab.com/g/p/-/work_items/5", "gitlab:gitlab.com/g/p#issue/5"),
      ("https://git.example.org/a/b/c/-/merge_requests/2/diffs", "gitlab:git.example.org/a/b/c#mr/2"),
    ])
  func gitlab(text: String, key: String) {
    #expect(keys(text) == [key])
  }

  @Test("Pages that are not a ticket or a request are not resources")
  func notResources() {
    #expect(keys("https://github.com/o/r/pull/new/feature") == [])
    #expect(keys("https://github.com/o/r/issues") == [])
    #expect(keys("https://gitlab.com/g/p/-/merge_requests/new?x=1") == [])
    #expect(keys("https://github.com/o/r/tree/main") == [])
    #expect(keys("ftp://github.com/o/r/pull/1") == [])
  }

  @Test("Labels: #36 on GitHub, !1315 for a GitLab merge request")
  func labels() {
    let found = ResourceRecognizer.urls(
      in: "https://gitlab.com/g/p/-/merge_requests/1315 https://github.com/o/r/pull/62",
      involvement: .viewed, at: date)
    #expect(found.map(\.label) == ["!1315", "#62"])
    #expect(found.map(\.kind) == [.pullRequest, .pullRequest])
    #expect(found.map(\.context) == ["g/p", "o/r"])
  }

  // MARK: - gh and glab

  private func sightings(_ command: String, directory: String? = "/repo", branch: String? = nil)
    -> [ResourceSighting]
  {
    ResourceRecognizer.commandSightings(command, directory: directory, branch: branch, at: date)
  }

  @Test("gh with a number: resolved against -R, or the folder's remote")
  func ghNumbers() {
    #expect(
      sightings("gh pr view 12 --json title")
        == [.reference(.github, .pullRequest, number: 12, repository: nil, directory: "/repo", involvement: .viewed, at: date)])
    #expect(
      sightings("gh issue comment 5 -R o/r --body 'Done 7'")
        == [.reference(.github, .issue, number: 5, repository: "o/r", directory: "/repo", involvement: .changed, at: date)])
    #expect(
      sightings("rtk gh pr merge --squash 9")
        == [.reference(.github, .pullRequest, number: 9, repository: nil, directory: "/repo", involvement: .changed, at: date)])
    #expect(
      sightings("glab mr note 3 -m hi")
        == [.reference(.gitlab, .pullRequest, number: 3, repository: nil, directory: "/repo", involvement: .changed, at: date)])
  }

  @Test("gh with a URL is read as the URL, with the command's involvement")
  func ghURL() {
    let found = sightings("gh pr review https://github.com/o/r/pull/4 --approve")
    #expect(found.count == 1)
    guard case .resource(let resource) = found.first else {
      Issue.record("no resource")
      return
    }
    #expect(resource.key == "github:github.com/o/r#4")
    #expect(resource.involvement == .changed)
  }

  @Test("gh without a number says nothing, unless its output does")
  func ghWithoutNumber() {
    #expect(sightings("gh pr view").isEmpty)
    #expect(ResourceRecognizer.readsOutput(of: "gh pr view"))
    #expect(!ResourceRecognizer.readsOutput(of: "gh pr view 3"))
    #expect(ResourceRecognizer.readsOutput(of: "cd x && gh pr create --fill"))
    #expect(!ResourceRecognizer.readsOutput(of: "gh issue list"))
    let created = ResourceRecognizer.sightings(
      in: .creationOutput(
        command: "gh pr create --fill", directory: "/repo",
        output: "https://github.com/o/r/pull/80\n", at: date),
      now: date)
    guard case .resource(let resource) = created.first else {
      Issue.record("no resource")
      return
    }
    #expect(resource.involvement == .created)
  }

  // MARK: - git

  @Test(
    "git: the branches it creates, switches to and pushes",
    arguments: [
      ("git checkout -b feat/36-journal", "feat/36-journal", SessionResource.Involvement.created),
      ("git switch -c x", "x", .created),
      ("git switch main", "main", .viewed),
      ("git push -u origin feat/x", "feat/x", .changed),
      ("git push origin HEAD:refs/heads/y", "y", .changed),
      ("git -C sub branch topic", "topic", .created),
    ])
  func gitBranches(command: String, name: String, involvement: SessionResource.Involvement) {
    let branches = sightings(command).compactMap { sighting -> (String, SessionResource.Involvement)? in
      guard case .branch(let found, _, let involvement, _) = sighting else { return nil }
      return (found, involvement)
    }
    #expect(branches.map(\.0) == [name])
    #expect(branches.map(\.1) == [involvement])
  }

  @Test("git push and commit without a branch take the branch the transcript says is checked out")
  func currentBranch() {
    let found = sightings("git push", branch: "feat/current")
    #expect(found == [.branch(name: "feat/current", directory: "/repo", involvement: .changed, at: date)])
    #expect(sightings("git push").isEmpty)
    #expect(
      sightings("git commit -am wip", branch: "b")
        == [.branch(name: "b", directory: "/repo", involvement: .changed, at: date)])
  }

  @Test("git: files, deletions and unknown words are not branches")
  func notBranches() {
    #expect(sightings("git checkout -- a.swift").isEmpty)
    #expect(sightings("git checkout .").isEmpty)
    #expect(sightings("git push --delete origin old").isEmpty)
    #expect(sightings("git branch -D old").isEmpty)
    #expect(sightings("git push origin $BRANCH").isEmpty)
    #expect(sightings("git switch -").isEmpty)
  }

  @Test("What a here-document writes is a file's content, not a resource used")
  func hereDocuments() {
    let command = """
      cat > Tests.swift <<'EOF'
      let url = "https://github.com/o/r/issues/12"
      git checkout -b nothing
      EOF
      git checkout -b real
      """
    #expect(
      sightings(command)
        == [.branch(name: "real", directory: "/repo", involvement: .created, at: date)])
  }

  @Test("cd moves the commands after it; git -C too")
  func directories() {
    #expect(
      sightings("cd ../other && git checkout -b x", directory: "/a/repo")
        == [.branch(name: "x", directory: "/a/other", involvement: .created, at: date)])
    #expect(
      sightings("cd $DIR && git checkout -b x", directory: "/a/repo").isEmpty)
  }

  @Test("git worktree add: the worktree, relative to the folder, and its new branch")
  func worktreeAdd() {
    #expect(
      sightings("git worktree add -b feat/36 ../repo-36 main", directory: "/a/repo")
        == [
          .worktree(path: "/a/repo-36", involvement: .created, at: date),
          .branch(name: "feat/36", directory: "/a/repo", involvement: .created, at: date),
        ])
  }

  @Test("A folder inside the worktrees agents make is a worktree")
  func worktreeFolders() {
    #expect(
      ResourceRecognizer.worktree(containing: "/r/.claude/worktrees/agent-3/Sources")
        == "/r/.claude/worktrees/agent-3")
    #expect(
      ResourceRecognizer.worktree(containing: "/Users/a/.codex/worktrees/ab12/repo/x")
        == "/Users/a/.codex/worktrees/ab12/repo")
    #expect(ResourceRecognizer.worktree(containing: "/r/Sources") == nil)
  }

  @Test("Branch names are normalized: origin/x and refs/heads/x are x")
  func normalizedBranches() {
    #expect(ResourceRecognizer.normalizedBranch("origin/x") == "x")
    #expect(ResourceRecognizer.normalizedBranch("refs/heads/feat/y") == "feat/y")
    #expect(ResourceRecognizer.normalizedBranch("HEAD") == nil)
    #expect(ResourceRecognizer.normalizedBranch("@{-1}") == nil)
  }
}

@Suite("Completing the resources with what Git knows")
struct ResourceResolutionTests {
  private let date = Date(timeIntervalSince1970: 1_800_000_000)

  actor Repositories: RepositoryIdentityResolving {
    let table: [String: RepositoryIdentity]
    init(_ table: [String: RepositoryIdentity]) { self.table = table }
    func identity(ofDirectory path: String) -> RepositoryIdentity? { table[path] }
  }

  private let github = RepositoryIdentity(
    rootPath: "/a/repo", commonDirectory: "/a/repo/.git",
    remote: RemoteRepository(remoteURL: "git@github.com:hadrienl/vibe-manager.git"))

  @Test("Remote URLs of every form")
  func remotes() {
    #expect(
      RemoteRepository(remoteURL: "git@github.com:o/r.git")
        == RemoteRepository(host: "github.com", path: "o/r"))
    #expect(
      RemoteRepository(remoteURL: "ssh://git@gitlab.example.org:2222/g/s/p.git")
        == RemoteRepository(host: "gitlab.example.org", path: "g/s/p"))
    #expect(
      RemoteRepository(remoteURL: "https://user@GitHub.com/o/r/")
        == RemoteRepository(host: "github.com", path: "o/r"))
    #expect(RemoteRepository(remoteURL: "/local/path") == nil)
  }

  @Test("A number and the URL of the same pull request are one resource")
  func numbersShareKeysWithURLs() async {
    let resolution = ResourceResolution(repositories: Repositories(["/a/repo": github]))
    let fromNumber = await resolution.resources(for: [
      .reference(.github, .pullRequest, number: 62, repository: nil, directory: "/a/repo", involvement: .changed, at: date)
    ])
    let fromURL = ResourceRecognizer.urls(
      in: "https://github.com/hadrienl/vibe-manager/pull/62", involvement: .viewed, at: date)
    #expect(fromNumber.map(\.key) == fromURL.map(\.key))
  }

  @Test("A branch seen from the clone and from one of its worktrees is one branch")
  func branchesAcrossWorktrees() async {
    let worktree = RepositoryIdentity(
      rootPath: "/a/repo", commonDirectory: "/a/repo/.git", remote: github.remote)
    let resolution = ResourceResolution(
      repositories: Repositories(["/a/repo": github, "/a/repo-36": worktree]))
    let resources = await resolution.resources(for: [
      .branch(name: "x", directory: "/a/repo", involvement: .viewed, at: date),
      .branch(name: "x", directory: "/a/repo-36", involvement: .changed, at: date),
    ])
    var journal = SessionJournal()
    journal.record(resources)
    #expect(journal.resources.count == 1)
    #expect(journal.resources.first?.involvement == .changed)
    #expect(
      journal.resources.first?.target
        == .branch(
          repositoryPath: "/a/repo",
          webURL: URL(string: "https://github.com/hadrienl/vibe-manager/tree/x")))
  }

  @Test("A number whose repository cannot be known is dropped")
  func unknownRepository() async {
    let resolution = ResourceResolution(repositories: Repositories([:]))
    let resources = await resolution.resources(for: [
      .reference(.github, .issue, number: 1, repository: nil, directory: "/nowhere", involvement: .viewed, at: date),
      .branch(name: "x", directory: "/nowhere", involvement: .viewed, at: date),
    ])
    #expect(resources.isEmpty)
  }

  @Test("gh -R names the repository, on github.com unless it names a host")
  func explicitRepository() async {
    let resolution = ResourceResolution(repositories: Repositories([:]))
    let resources = await resolution.resources(for: [
      .reference(.github, .issue, number: 3, repository: "o/r", directory: nil, involvement: .viewed, at: date),
      .reference(.github, .issue, number: 4, repository: "ghe.example/o/r", directory: nil, involvement: .viewed, at: date),
    ])
    #expect(resources.map(\.key) == ["github:github.com/o/r#3", "github:ghe.example/o/r#4"])
  }
}
