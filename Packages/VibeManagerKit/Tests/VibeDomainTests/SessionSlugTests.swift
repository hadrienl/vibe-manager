import Foundation
import Testing
import VibeDomain

@Suite("The slug of a session")
struct SessionSlugTests {
  private func derived(_ title: String) -> String {
    SessionSlug.derived(fromTitle: title, fallback: { "abc123" }).rawValue
  }

  @Test("A French title becomes something typed without thinking")
  func accentsAndPunctuation() {
    #expect(derived("Refonte de la facturation") == "refonte-de-la-facturation")
    #expect(derived("Refonte — facturation (V2)") == "refonte-facturation-v2")
    #expect(derived("Œuvre à l’été : ça marche ?") == "oeuvre-a-l-ete-ca-marche")
    #expect(derived("Straße über Łódź") == "strasse-uber-lodz")
  }

  @Test("Emoji and separators leave nothing behind them")
  func emojiAndSeparators() {
    #expect(derived("🚀 Ship it 🚀") == "ship-it")
    #expect(derived("  --__..  api  ..__--  ") == "api")
  }

  @Test("A title that leaves nothing falls back to a recognisable name")
  func fallback() {
    #expect(derived("") == "session-abc123")
    #expect(derived("—  !!! …") == "session-abc123")
    #expect(derived("🚀🚀") == "session-abc123")
  }

  @Test("A long title is cut at forty characters, on a word boundary")
  func longTitle() {
    let title = String(repeating: "facturation ", count: 20)
    let slug = derived(title)

    #expect(slug.count <= SessionSlug.derivedLength)
    #expect(!slug.hasSuffix("-"))
    #expect(slug.split(separator: "-").allSatisfy { $0 == "facturation" })
  }

  @Test("A single word longer than the limit is cut where it is")
  func longWord() {
    let slug = derived(String(repeating: "a", count: 200))

    #expect(slug == String(repeating: "a", count: SessionSlug.derivedLength))
  }

  @Test("The branch is the slug under the application's prefix")
  func branchName() throws {
    let slug = try #require(SessionSlug("refonte-facturation"))

    #expect(slug.branchName == "vibe/refonte-facturation")
  }

  @Test(
    "What Git would refuse is refused in the field",
    arguments: [
      ("", SessionSlugProblem.empty),
      (".hidden", .leadingDot),
      ("-flag", .leadingDash),
      ("trailing.", .trailingDot),
      ("name.lock", .lockSuffix),
      ("a..b", .doubleDot),
      ("at@{home", .reservedSequence),
      ("with space", .forbiddenCharacter(" ")),
      ("a/b", .forbiddenCharacter("/")),
      ("tilde~", .forbiddenCharacter("~")),
      ("colon:", .forbiddenCharacter(":")),
      ("question?", .forbiddenCharacter("?")),
    ]
  )
  func invalidSlugs(candidate: String, problem: SessionSlugProblem) {
    #expect(SessionSlug.validationProblem(for: candidate) == problem)
    #expect(SessionSlug(candidate) == nil)
  }

  @Test("A slug typed by hand may be longer than a derived one, up to a limit")
  func typedLength() {
    #expect(SessionSlug(String(repeating: "a", count: SessionSlug.maximumLength)) != nil)
    #expect(
      SessionSlug.validationProblem(for: String(repeating: "a", count: 65))
        == .tooLong(limit: SessionSlug.maximumLength))
  }

  @Test("A taken slug proposes the next free suffix, and never replaces the original")
  func suffixes() throws {
    let slug = try #require(SessionSlug("api"))
    let taken: Set<String> = ["api", "api-2"]

    let proposed = slug.firstAvailable { taken.contains($0.rawValue) }

    #expect(proposed.rawValue == "api-3")
    #expect(slug.rawValue == "api")
    #expect(slug.firstAvailable { _ in false } == slug)
  }

  @Test("A suffix still fits when the slug is already at the limit")
  func suffixAtTheLimit() throws {
    let slug = try #require(SessionSlug(String(repeating: "a", count: SessionSlug.maximumLength)))

    let proposed = slug.firstAvailable { $0 == slug }

    #expect(proposed.rawValue.count <= SessionSlug.maximumLength)
    #expect(proposed.rawValue.hasSuffix("-2"))
  }

  @Test("A slug is stored as a plain string and refused back when it is not valid")
  func coding() throws {
    let slug = try #require(SessionSlug("refonte"))
    let data = try JSONEncoder().encode([slug])

    #expect(String(decoding: data, as: UTF8.self) == #"["refonte"]"#)
    #expect(try JSONDecoder().decode([SessionSlug].self, from: data) == [slug])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([SessionSlug].self, from: Data(#"["a b"]"#.utf8))
    }
  }
}

@Suite("The slug and the repositories of a draft")
struct SessionDraftRepositoryTests {
  @Test("The slug follows the name until it is typed in")
  func slugFollowsTheName() {
    var draft = SessionDraft(name: "Refonte de la facturation")
    #expect(draft.slugText == "refonte-de-la-facturation")

    draft.name = "Refonte des paiements"
    #expect(draft.slugText == "refonte-des-paiements")

    draft.customSlug = "billing"
    draft.name = "Something else entirely"
    #expect(draft.slugText == "billing")

    draft.customSlug = nil
    #expect(draft.slugText == "something-else-entirely")
  }

  @Test("An empty name keeps one fallback for the whole draft")
  func fallbackIsStable() {
    let draft = SessionDraft(name: "", slugFallback: "0a1b2c")

    #expect(draft.slugText == "session-0a1b2c")
    #expect(draft.slugText == draft.slugText)
  }

  @Test("A draft does not judge its slug: only a plan knows whether it will name a branch")
  func invalidSlugIsLeftToThePlan() {
    let draft = SessionDraft(
      name: "Task",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp",
      customSlug: "a b"
    )

    #expect(draft.validate().isEmpty)
    #expect(draft.slug == nil)
  }

  @Test("The session keeps the slug it was created with, whatever it is renamed to")
  func slugIsStableAfterRenaming() throws {
    let draft = SessionDraft(
      name: "Refonte de la facturation",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp"
    )
    var session = draft.session(slug: draft.slug)
    session.name = "Something else"

    #expect(session.slug?.rawValue == "refonte-de-la-facturation")
    #expect(session.slug?.branchName == "vibe/refonte-de-la-facturation")
  }

  @Test("A slug already given is never replaced")
  func adoptedSlugIsFinal() throws {
    var session = WorkSession(name: "Stored before worktrees")
    #expect(session.slug == nil)

    session.adoptSlugIfMissing(try #require(SessionSlug("first")))
    session.adoptSlugIfMissing(try #require(SessionSlug("second")))

    #expect(session.slug?.rawValue == "first")
  }

  @Test("The main folder is the first repository, and replacing it forgets its choices")
  func mainFolder() {
    var draft = SessionDraft(workingDirectoryPath: "/work/api")
    draft.repositories[0].mode = .inPlace
    draft.repositories.append(SessionDraftRepository(path: "/work/web"))

    draft.workingDirectoryPath = "/work/billing"

    #expect(draft.repositories.map(\.path) == ["/work/billing", "/work/web"])
    #expect(draft.repositories[0].mode == nil)
  }

  @Test("Without a plan, every folder of a draft is attached in place")
  func sessionWithoutPlan() {
    let draft = SessionDraft(
      name: "Task",
      providerID: "claude-code",
      repositories: [
        SessionDraftRepository(path: "/work/api"), SessionDraftRepository(path: "~/web"),
      ]
    )

    let session = draft.session()

    #expect(session.repositories.map(\.mode) == [.inPlace, .inPlace])
    #expect(session.repositories.last?.rootPath.hasPrefix("/") == true)
  }
}

@Suite("A repository attached to a session")
struct RepositoryContextTests {
  @Test("A worktree is worked in where it is, and not at all until it exists")
  func effectivePath() {
    let prepared = RepositoryContext(
      rootPath: "/work/api", mode: .worktree, worktreePath: "/wt/api", branchName: "vibe/x")
    let failed = RepositoryContext(
      rootPath: "/work/api",
      mode: .worktree,
      failure: RepositoryPreparationFailure(message: "no", remedy: "retry")
    )
    let inPlace = RepositoryContext(rootPath: "/work/web", mode: .inPlace)

    #expect(prepared.effectivePath == "/wt/api")
    #expect(failed.effectivePath == nil)
    #expect(inPlace.effectivePath == "/work/web")
  }

  @Test("A worktree without a path, and not failed, is not a session that can be stored")
  func invalidAttachment() {
    let session = WorkSession(
      name: "Broken",
      repositories: [RepositoryContext(rootPath: "/work/api", mode: .worktree)]
    )

    #expect(throws: WorkSessionValidationError.invalidRepositoryAttachment) {
      try session.validate()
    }
  }
}
