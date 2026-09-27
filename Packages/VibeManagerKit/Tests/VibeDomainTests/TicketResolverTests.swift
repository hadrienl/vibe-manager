import Foundation
import Testing

@testable import VibeDomain

@Suite("Recognising tickets in what a session names, and reading their titles (#89)")
struct TicketResolverTests {
  private let presets = TicketResolverSet(TicketResolverPresets.all)

  // MARK: Addresses

  @Test("Addresses are found in order, without the punctuation that closes the sentence")
  func extraction() {
    let texts = [
      "Voir (https://github.com/acme/app/issues/42).",
      "Et https://gitlab.com/g/p/-/issues/7, puis <https://example.com/a> ou "
        + "[lien](https://linear.app/acme/issue/ENG-12) — https://fr.wikipedia.org/wiki/A_(b)",
      "Encore https://github.com/acme/app/issues/42.",
    ]
    #expect(
      TicketLinkExtractor.addresses(in: texts) == [
        "https://github.com/acme/app/issues/42",
        "https://gitlab.com/g/p/-/issues/7",
        "https://example.com/a",
        "https://linear.app/acme/issue/ENG-12",
        "https://fr.wikipedia.org/wiki/A_(b)",
      ])
  }

  @Test("No more addresses than the limit are looked at")
  func addressLimit() {
    let text = (1...40).map { "https://example.com/\($0)" }.joined(separator: " ")
    #expect(TicketLinkExtractor.addresses(in: [text]).count == TicketLinkExtractor.addressLimit)
  }

  // MARK: Presets

  @Test(
    "Each preset recognises its tickets, whatever the tab or the anchor",
    arguments: [
      ("https://github.com/acme/app/issues/42", "acme/app#42"),
      ("https://github.com/acme/app/pull/12/files", "acme/app#12"),
      ("https://GitHub.com/acme/app/issues/42#issuecomment-1", "acme/app#42"),
      ("https://gitlab.com/group/sub/project/-/issues/7", "group/sub/project#7"),
      ("https://gitlab.com/group/project/-/work_items/8?x=1", "group/project#8"),
      ("https://gitlab.com/group/project/-/merge_requests/9/diffs", "group/project!9"),
      ("https://acme.atlassian.net/browse/PROJ-123", "PROJ-123"),
      ("https://linear.app/acme/issue/ENG-12/fix-the-thing", "ENG-12"),
    ])
  func presetRecognition(address: String, shortID: String) {
    #expect(presets.recognize(address)?.shortID == shortID)
  }

  @Test(
    "What is not a ticket is recognised by none",
    arguments: [
      "https://github.com/acme/app", "https://github.com/acme/app/issues",
      "https://github.com/acme/app/issues/42abc", "https://example.com/issues/42",
      "https://evil.example/github.com/acme/app/issues/1", "ftp://github.com/acme/app/issues/1",
      "https://gitlab.example.com/g/p/-/issues/1",
    ])
  func notATicket(address: String) {
    #expect(presets.recognize(address) == nil)
  }

  @Test("The tickets of the texts come once each, in order, and a disabled resolver sees none")
  func ticketsInTexts() {
    let texts = [
      "https://github.com/acme/app/issues/42",
      "Fix https://github.com/acme/app/issues/42#top and https://acme.atlassian.net/browse/PROJ-1",
    ]
    #expect(presets.tickets(in: texts).map(\.shortID) == ["acme/app#42", "PROJ-1"])
    var github = TicketResolverPresets.github
    github.isEnabled = false
    let without = TicketResolverSet([github, TicketResolverPresets.jiraCloud])
    #expect(without.tickets(in: texts).map(\.shortID) == ["PROJ-1"])
  }

  @Test("A page is the ticket's only when the same resolver gives it the same identifier")
  func isPage() throws {
    let ticket = try #require(presets.recognize("https://github.com/acme/app/issues/42"))
    #expect(presets.isPage(URL(string: "https://github.com/acme/app/issues/42")!, of: ticket))
    #expect(!presets.isPage(URL(string: "https://github.com/acme/app/issues/43")!, of: ticket))
    #expect(!presets.isPage(URL(string: "https://github.com/login?return_to=x")!, of: ticket))
  }

  // MARK: Titles

  @Test(
    "The site's words are taken off the page's title",
    arguments: [
      ("Permettre l'export CSV · Issue #42 · acme/app", "Permettre l'export CSV", 0),
      ("Fix the crash by octocat · Pull Request #12 · acme/app", "Fix the crash", 0),
      ("Fix the crash (#7) · Issues · Group / Project · GitLab", "Fix the crash", 1),
      ("Fix the crash (!9) · Merge requests · Group / Project · GitLab", "Fix the crash", 2),
      ("[PROJ-123] Fix the crash - Jira", "Fix the crash", 3),
      ("ENG-12 Fix the crash", "Fix the crash", 4),
    ])
  func cleanup(raw: String, expected: String, preset: Int) throws {
    let resolver = try #require(CompiledTicketResolver(TicketResolverPresets.all[preset]))
    #expect(resolver.cleanTitle(raw) == expected)
  }

  @Test("A title that only names the site, or nothing, is not a title")
  func notATitle() throws {
    let resolver = try #require(CompiledTicketResolver(TicketResolverPresets.jiraCloud))
    #expect(resolver.cleanTitle("   ") == nil)
    #expect(resolver.cleanTitle("Jira Cloud") == nil)
  }

  @Test("A title is kept on one line, bounded")
  func titleText() {
    #expect(TicketTitleText.normalized("  a\nb\t c\u{7}  ") == "a b c")
    let long = String(repeating: "x", count: 300)
    #expect(TicketTitleText.bounded(long).count == TicketTitleText.lengthLimit)
    #expect(TicketTitleText.bounded(long).hasSuffix("…"))
  }

  // MARK: Configuration

  @Test("A resolver says everything wrong with it")
  func validation() {
    let resolver = TicketResolver(
      name: " ", pattern: "https://x/(?<n>[0-9]+", shortID: "", titleCleanup: ["("])
    #expect(
      resolver.validate() == [
        .nameMissing, .patternInvalid, .shortIDMissing, .cleanupInvalid(index: 0),
      ])
    let unknown = TicketResolver(
      name: "Redmine", pattern: #"https://redmine\.acme\.fr/issues/(?<number>[0-9]+)"#,
      shortID: "#{number} {project}")
    #expect(unknown.validate() == [.unknownPlaceholder("project")])
    let bare = TicketResolver(name: "Bare", pattern: "https://x/", shortID: "x")
    #expect(bare.validate() == [.patternWithoutCaptures])
  }

  @Test("A resolver for a tool not shipped is written in settings and used")
  func customResolver() {
    let redmine = TicketResolver(
      name: "Redmine Acme", pattern: #"https://redmine\.acme\.fr/issues/(?<number>[0-9]+)"#,
      shortID: "#{number}", titleCleanup: [#"^[^#]*#[0-9]+: "#, #" - Redmine$"#])
    #expect(redmine.validate().isEmpty)
    let set = TicketResolverSet([redmine])
    #expect(set.recognize("https://redmine.acme.fr/issues/77")?.shortID == "#77")
    #expect(
      set.resolver(id: redmine.id)?.cleanTitle("Anomalie #77: Le rapport plante - Redmine")
        == "Le rapport plante")
  }

  @Test("The line follows the format, and an invalid format falls back to the standard one")
  func lineFormat() {
    #expect(
      TicketLineFormat.standard.line(id: "acme/app#42", title: "Export", url: "https://x/42")
        == "[acme/app#42] Export — https://x/42")
    #expect(
      TicketLineFormat("- {title} ({id})").line(id: "A-1", title: "T", url: "u") == "- T (A-1)")
    #expect(!TicketLineFormat("{id} {url}").isValid)
    #expect(!TicketLineFormat("{title} {nope}").isValid)
    #expect(TicketLineFormat("{id} {url}").line(id: "A-1", title: "T", url: "u") == "[A-1] T — u")
  }

  // MARK: Presets across versions

  @Test("A preset left alone follows the shipped revision; one changed or deleted stays so")
  func presetMerge() {
    var old = TicketResolverPresets.github
    old.pattern = "https://github.com/(?<x>old)"
    old.preset?.revision = 0
    old.isEnabled = false
    var changed = TicketResolverPresets.linear
    changed.shortID = "{workspace}:{key}"
    changed.preset = .init(id: "linear", revision: 0, isModified: true)
    let merged = TicketResolverPresets.merge(
      stored: [old, changed], knownPresets: ["github", "linear", "jira-cloud"])
    #expect(merged[0].pattern == TicketResolverPresets.github.pattern)
    #expect(merged[0].isEnabled == false)
    #expect(merged[1].shortID == "{workspace}:{key}")
    // Jira was known and is not stored: deleted. The two GitLab ones are new: added.
    #expect(!merged.contains { $0.preset?.id == "jira-cloud" })
    #expect(merged.contains { $0.preset?.id == "gitlab-issues" })
    #expect(merged.contains { $0.preset?.id == "gitlab-merge-requests" })
  }

  @Test("Changing a preset's rules marks it as the user's, restoring it takes the shipped rules")
  func presetChanges() {
    var resolver = TicketResolverPresets.github
    resolver.name = "GitHub Enterprise"
    #expect(TicketResolverPresets.markingChanges(resolver).preset?.isModified == false)
    resolver.shortID = "#{number}"
    let marked = TicketResolverPresets.markingChanges(resolver)
    #expect(marked.preset?.isModified == true)
    let restored = TicketResolverPresets.restoring(marked)
    #expect(restored.shortID == TicketResolverPresets.github.shortID)
    #expect(restored.preset?.isModified == false)
  }

  @Test("A ticket found in the prompt is stored as detected, and shown before the branch's")
  func detectedTicket() {
    let url = URL(string: "https://github.com/acme/app/issues/42")!
    let resolved = TicketResolution.resolve(
      stored: SessionTicket(url: url, source: .detected), branch: "feat/7-x",
      repository: RepositoryWebAddress.of(remote: "git@github.com:acme/app.git"))
    #expect(resolved == TicketResolution.Resolved(url: url, origin: .detected))
  }
}
