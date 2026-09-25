import Foundation
import Testing

@testable import VibeDomain

@Suite("Reading a session's ticket from addresses, remotes and branches")
struct SessionTicketTests {
  // MARK: Remotes

  @Test(
    "A Git remote gives the repository's web address",
    arguments: [
      ("git@github.com:hadrienl/vibe-manager.git", "https://github.com/hadrienl/vibe-manager"),
      ("https://github.com/hadrienl/vibe-manager", "https://github.com/hadrienl/vibe-manager"),
      ("https://github.com/hadrienl/vibe-manager.git/", "https://github.com/hadrienl/vibe-manager"),
      (
        "ssh://git@github.com/hadrienl/vibe-manager.git", "https://github.com/hadrienl/vibe-manager"
      ),
      ("git@gitlab.com:group/sub/project.git", "https://gitlab.com/group/sub/project"),
      (
        "ssh://git@gitlab.example.com:2222/group/sub/project.git",
        "https://gitlab.example.com/group/sub/project"
      ),
      ("https://user@GitLab.Company.io/g/p", "https://gitlab.company.io/g/p"),
    ])
  func remote(remote: String, expected: String) {
    #expect(RepositoryWebAddress.of(remote: remote)?.url.absoluteString == expected)
  }

  @Test(
    "What is not a remote on a known forge gives nothing",
    arguments: [
      "/Users/me/repo", "../repo", "C:/repo", "git@bitbucket.org:o/r.git",
      "https://example.com/o/r", "git@github.com:onlyowner", "https://github.com/o/../r", "",
      "file:///tmp/repo",
    ])
  func notARemote(remote: String) {
    #expect(RepositoryWebAddress.of(remote: remote) == nil)
  }

  @Test("A ticket's address is the forge's own")
  func issueAddress() {
    let github = RepositoryWebAddress(forge: .github, host: "github.com", path: "o/r")
    let gitlab = RepositoryWebAddress(forge: .gitlab, host: "gitlab.com", path: "g/s/p")
    #expect(github.issueURL(number: 12).absoluteString == "https://github.com/o/r/issues/12")
    #expect(gitlab.issueURL(number: 12).absoluteString == "https://gitlab.com/g/s/p/-/issues/12")
  }

  // MARK: Addresses

  @Test(
    "A pasted ticket or merge request address is read whatever the browser left on it",
    arguments: [
      (
        "https://github.com/o/r/issues/69#issuecomment-1", "https://github.com/o/r/issues/69", "#69"
      ),
      ("https://github.com/o/r/pull/74/files", "https://github.com/o/r/pull/74", "#74"),
      ("https://github.com/o/r/pull/74/", "https://github.com/o/r/pull/74", "#74"),
      (
        "https://gitlab.com/g/s/p/-/merge_requests/1315/diffs?view=inline",
        "https://gitlab.com/g/s/p/-/merge_requests/1315", "!1315"
      ),
      ("https://gitlab.com/g/p/-/issues/7", "https://gitlab.com/g/p/-/issues/7", "#7"),
      ("https://gitlab.com/g/p/-/work_items/7", "https://gitlab.com/g/p/-/issues/7", "#7"),
    ])
  func pastedAddress(pasted: String, canonical: String, label: String) throws {
    let reference = try #require(IssueReference.parse(URL(string: pasted)!))
    #expect(reference.url.absoluteString == canonical)
    #expect(reference.shortLabel == label)
  }

  @Test(
    "Other pages of a forge are not tickets",
    arguments: [
      "https://github.com/o/r", "https://github.com/o/r/issues",
      "https://github.com/o/r/blob/main/x",
      "https://gitlab.com/g/p/-/tree/main", "https://example.com/o/r/issues/1",
      "https://github.com/o/r/issues/0",
    ])
  func notATicket(address: String) {
    #expect(IssueReference.parse(URL(string: address)!) == nil)
  }

  // MARK: Branches

  @Test(
    "A branch named after a ticket gives its number",
    arguments: [
      ("feat/12-web-view", 12), ("fix/12_crash", 12), ("12-web-view", 12), ("issue-12", 12),
      ("gh-12", 12), ("hadrien/feat/69-web-view", 69), ("feature/Issue-7", 7), ("12", nil),
      ("ticket-40", 40),
    ] as [(String, Int?)])
  func branch(branch: String, number: Int?) {
    #expect(BranchTicketInference.issueNumber(branch: branch) == number)
  }

  @Test(
    "Branches that only hold numbers are not tickets",
    arguments: [
      "main", "release/1.2", "v12", "2026-09-25-cleanup", "dependabot/npm/lodash-4.17",
      "renovate/12-deps", "feat/web-view", "12-3", "feat/12-", "12.1-fix",
    ])
  func notATicketBranch(branch: String) {
    #expect(BranchTicketInference.issueNumber(branch: branch) == nil)
  }

  // MARK: Resolution

  private let repository = RepositoryWebAddress(forge: .github, host: "github.com", path: "o/r")

  @Test("A ticket typed by hand wins over the branch")
  func manualFirst() {
    let manual = SessionTicket(url: URL(string: "https://example.com/t/1")!, source: .manual)
    let resolved = TicketResolution.resolve(
      stored: manual, branch: "feat/12-x", repository: repository)
    #expect(resolved?.url.absoluteString == "https://example.com/t/1")
    #expect(resolved?.origin == .manual)
    #expect(resolved?.label == "example.com")
  }

  @Test("Without a stored ticket, the branch gives one")
  func branchDeduced() {
    let resolved = TicketResolution.resolve(
      stored: nil, branch: "feat/12-x", repository: repository)
    #expect(resolved?.url.absoluteString == "https://github.com/o/r/issues/12")
    #expect(resolved?.origin == .branch)
    #expect(resolved?.label == "#12")
  }

  @Test("A ticket removed on purpose is not brought back by the branch")
  func removedStaysRemoved() {
    #expect(
      TicketResolution.resolve(stored: .removed, branch: "feat/12-x", repository: repository)
        == nil)
  }

  @Test("Nothing is deduced without a known forge")
  func unknownForge() {
    #expect(TicketResolution.resolve(stored: nil, branch: "feat/12-x", repository: nil) == nil)
  }

  @Test("What is typed in a ticket field becomes an address")
  func typed() {
    #expect(
      TicketInput.url(from: " #12 ", repository: repository)?.absoluteString
        == "https://github.com/o/r/issues/12")
    #expect(TicketInput.url(from: "12", repository: nil) == nil)
    #expect(
      TicketInput.url(from: "https://github.com/o/r/pull/3/files", repository: nil)?.absoluteString
        == "https://github.com/o/r/pull/3")
    #expect(
      TicketInput.url(from: "https://linear.app/t/ABC-1", repository: nil)?.absoluteString
        == "https://linear.app/t/ABC-1")
    #expect(TicketInput.url(from: "javascript:alert(1)", repository: repository) == nil)
    #expect(TicketInput.url(from: "", repository: repository) == nil)
  }

  @Test("A draft's ticket is the typed one, else its template's `ticket` field")
  func draftTicket() throws {
    var draft = SessionDraft(name: "x", ticketText: "#5")
    #expect(draft.ticket(repository: repository)?.source == .manual)
    #expect(
      draft.session(repository: repository).ticket?.url?.absoluteString
        == "https://github.com/o/r/issues/5")

    let template = PromptTemplate(name: "T", body: "Work on {{Ticket}}")
    var fill = PromptTemplateFill(template: template)
    fill.setValue("https://github.com/o/r/issues/9", for: "ticket")
    draft = SessionDraft(name: "x", templateFill: fill)
    let ticket = try #require(draft.ticket(repository: nil))
    #expect(ticket.source == .template)
    #expect(ticket.url?.absoluteString == "https://github.com/o/r/issues/9")
  }

  // MARK: Browser state

  @Test("A tab that cannot be read is dropped, not the whole view")
  func lenientState() throws {
    let json = """
      {"tabs":[{"id":"11111111-1111-1111-1111-111111111111","url":"http://localhost:5173/","title":"A","openedBy":"agent"},
      {"id":"not-a-uuid"},
      {"id":"22222222-2222-2222-2222-222222222222","url":"https://x.dev","openedBy":"future"}],
      "activeTabID":"33333333-3333-3333-3333-333333333333","isVisible":true,"later":1}
      """
    let state = try JSONDecoder().decode(SessionBrowserState.self, from: Data(json.utf8))
    #expect(state.tabs.count == 2)
    #expect(state.tabs[0].openedBy == .agent)
    #expect(state.tabs[1].openedBy == .user)
    #expect(state.tabs[1].title == "")
    // Naming a tab that is not there puts the ticket in front instead.
    #expect(state.activeTabID == nil)
    #expect(state.isVisible)
  }
}
