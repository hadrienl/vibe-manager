import Foundation
import Testing
import VibeApplication
import VibeDomain

private let billing = slug("refonte-facturation")

private func worktree(
  _ name: String,
  root: String? = nil,
  failure: RepositoryPreparationFailure? = nil
) -> RepositoryContext {
  RepositoryContext(
    rootPath: root ?? "/Users/alice/code/\(name)",
    mode: .worktree,
    worktreePath: failure == nil
      ? "/Users/alice/VibeManager/Worktrees/refonte-facturation/\(name)" : nil,
    branchName: billing.branchName,
    baseRevision: "3f2a1c9d8e7f6a5b",
    createdByVibeManager: failure == nil,
    failure: failure
  )
}

private func inPlace(_ name: String, branch: String? = "vibe/refonte-facturation")
  -> RepositoryContext
{
  RepositoryContext(rootPath: "/Users/alice/code/\(name)", mode: .inPlace, branchName: branch)
}

private func session(
  _ repositories: [RepositoryContext],
  slug: SessionSlug? = billing,
  prompt: String = "",
  notes: String? = nil
) -> WorkSession {
  WorkSession(
    name: "Refonte de la facturation",
    initialPrompt: prompt,
    agent: SessionAgentConfiguration(providerID: "claude-code"),
    status: .closed,
    createdAt: Date(timeIntervalSince1970: 1_699_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
    closedAt: Date(timeIntervalSince1970: 1_700_000_100),
    repositories: repositories,
    slug: slug,
    notes: notes
  )
}

@Suite("The convention handed to the agent")
struct SessionConventionTests {
  private let builder = SessionConventionBuilder()

  @Test("One repository worked in place has nothing to coordinate, and gets no block")
  func singleInPlace() {
    #expect(builder(for: session([inPlace("web")])) == nil)
    #expect(
      builder(
        for: session([RepositoryContext(rootPath: "/Users/alice/notes", mode: .plainFolder)]))
        == nil)
    #expect(builder(for: session([])) == nil)
  }

  @Test("One worktree is enough for a block: the agent must not work in the clone")
  func singleWorktree() throws {
    let text = try #require(builder(for: session([worktree("api")])))

    #expect(text.hasPrefix("Vibe Manager runs this session in one repository"))
    #expect(text.contains("Branch: vibe/refonte-facturation."))
    #expect(text.contains("never in the original clones"))
  }

  @Test("Two repositories give exactly the block the ticket describes")
  func golden() {
    let text = builder(for: session([worktree("api"), inPlace("web")]))

    #expect(
      text == """
        Vibe Manager runs this session across 2 repositories, under one convention.

        Branch: vibe/refonte-facturation — the same name in every repository.
        Work in the paths listed below, never in the original clones.

        - /Users/alice/VibeManager/Worktrees/refonte-facturation/api
          worktree of /Users/alice/code/api, on vibe/refonte-facturation (from 3f2a1c9).
        - /Users/alice/code/web
          attached in place, on vibe/refonte-facturation.

        If you need another branch, create it from vibe/refonte-facturation and give it the \
        same name in every repository. Never delete a branch or a worktree: Vibe Manager does \
        not, and neither should you.
        """)
  }

  @Test("A repository that was not prepared is named, with the instruction to leave it alone")
  func failedRepository() throws {
    let failure = RepositoryPreparationFailure(message: "the branch exists", remedy: "…")
    let text = try #require(
      builder(for: session([worktree("api"), worktree("web", failure: failure)])))

    #expect(text.contains("- /Users/alice/code/web\n  not prepared (the branch exists)"))
    #expect(text.contains("do not work in it"))
  }

  @Test("A session stored without a slug keeps each repository on its own branch")
  func legacySession() throws {
    let text = try #require(
      builder(for: session([inPlace("api", branch: "main"), inPlace("web")], slug: nil)))

    #expect(text.contains("Each repository stays on the branch named below."))
    #expect(!text.contains("Branch:"))
  }

  @Test("A summarised block keeps the main repository whole and names the others")
  func summarised() throws {
    let text = try #require(
      builder(for: session([worktree("api"), worktree("web"), inPlace("lib")]), summarized: true))

    #expect(text.contains("/Users/alice/VibeManager/Worktrees/refonte-facturation/api"))
    #expect(text.contains("- and 2 more, attached the same way: web, lib."))
    #expect(!text.contains("/Users/alice/code/lib"))
  }

  @Test("A repository added to a running session is announced with its path and the branch")
  func addendum() {
    let text = builder.addendum(for: worktree("web"), slug: billing)

    #expect(text.contains("/Users/alice/VibeManager/Worktrees/refonte-facturation/web"))
    #expect(text.contains("work on vibe/refonte-facturation"))
  }
}

@Suite("Where the agent of a session is started")
struct SessionLaunchContextTests {
  @Test("The agent starts in the main repository's worktree, and reaches the others")
  func mainWorktreeIsTheWorkingDirectory() throws {
    let context = try SessionLaunchContext.make(
      for: session([worktree("api"), inPlace("web")]), worktreeRootPath: "/wt")

    #expect(
      context.workingDirectoryPath == "/Users/alice/VibeManager/Worktrees/refonte-facturation/api")
    #expect(context.additionalWorkingDirectoryPaths == ["/Users/alice/code/web"])
  }

  @Test("A main repository attached in place starts the agent in its clone")
  func mainInPlace() throws {
    let context = try SessionLaunchContext.make(
      for: session([inPlace("web"), worktree("api")]), worktreeRootPath: "/wt")

    #expect(context.workingDirectoryPath == "/Users/alice/code/web")
    #expect(
      context.additionalWorkingDirectoryPaths == [
        "/Users/alice/VibeManager/Worktrees/refonte-facturation/api"
      ])
  }

  @Test("An excluded or unprepared repository is left out of the launch, and said to be")
  func exclusions() throws {
    let failure = RepositoryPreparationFailure(message: "no", remedy: "…")
    let web = inPlace("web")
    let context = try SessionLaunchContext.make(
      for: session([worktree("api"), web, worktree("lib", failure: failure)]),
      worktreeRootPath: "/wt",
      excluding: [web.id]
    )

    #expect(context.additionalWorkingDirectoryPaths.isEmpty)
    #expect(context.leftOut.map(\.displayName) == ["web", "lib"])
  }

  @Test("A main repository that was not prepared leaves nowhere to start")
  func mainUnprepared() {
    let failure = RepositoryPreparationFailure(message: "no", remedy: "…")
    #expect(throws: SessionLaunchContext.Problem.self) {
      try SessionLaunchContext.make(
        for: session([worktree("api", failure: failure), inPlace("web")]),
        worktreeRootPath: "/wt")
    }
  }

  @Test("The slug, the branch and the session folder are handed to the process")
  func environment() throws {
    let context = try SessionLaunchContext.make(
      for: session([worktree("api")]), worktreeRootPath: "/wt")

    #expect(context.environment["VIBE_SESSION_SLUG"] == "refonte-facturation")
    #expect(context.environment["VIBE_SESSION_BRANCH"] == "vibe/refonte-facturation")
    // Where the worktrees really are, not where the current root would put new ones.
    #expect(
      context.environment["VIBE_SESSION_ROOT"]
        == "/Users/alice/VibeManager/Worktrees/refonte-facturation")
  }

  @Test("Without a worktree, the session root is the main folder")
  func rootWithoutWorktree() throws {
    let context = try SessionLaunchContext.make(
      for: session([inPlace("web")]), worktreeRootPath: "/wt")

    #expect(context.environment["VIBE_SESSION_ROOT"] == "/Users/alice/code/web")
  }

  @Test("The convention opens the prompt, and the user's prompt follows it untouched")
  func conventionFirst() throws {
    let context = try SessionLaunchContext.make(
      for: session([worktree("api"), inPlace("web")]), worktreeRootPath: "/wt")
    let prompt = try #require(context.prompt(with: "Split the invoice builder."))

    #expect(prompt.hasPrefix("Vibe Manager runs this session across 2 repositories"))
    #expect(prompt.hasSuffix("\n\nSplit the invoice builder."))
  }

  @Test("Without a prompt, the convention is sent alone and holds the agent back")
  func holdSentence() throws {
    let context = try SessionLaunchContext.make(
      for: session([worktree("api")]), worktreeRootPath: "/wt")
    let prompt = try #require(context.prompt(with: "  "))

    #expect(prompt.hasSuffix(SessionConventionBuilder.holdSentence))
  }

  @Test("A single repository in place changes nothing about the prompt")
  func noBlock() throws {
    let context = try SessionLaunchContext.make(
      for: session([inPlace("web")]), worktreeRootPath: "/wt")

    #expect(context.prompt(with: "Just do it.") == "Just do it.")
    #expect(context.prompt(with: nil) == nil)
  }

  @Test("When the whole does not fit, the list shrinks and the user's prompt does not")
  func budget() throws {
    let repositories = (1...12).map { worktree("repository-with-a-long-name-\($0)") }
    let context = try SessionLaunchContext.make(
      for: session(repositories), worktreeRootPath: "/wt")
    let userPrompt = String(repeating: "x", count: 400)
    let full = try #require(context.convention).utf8.count + 2 + userPrompt.utf8.count
    let prompt = try #require(context.prompt(with: userPrompt, byteLimit: full - 1))

    #expect(prompt.contains("- and 11 more, attached the same way"))
    #expect(prompt.hasSuffix("\n\n" + userPrompt))
  }
}

@Suite("The convention in a restart summary")
struct SessionBriefConventionTests {
  @Test("The convention comes right after the heading")
  func placement() {
    let brief = SessionContextBriefBuilder()(
      for: session([worktree("api"), inPlace("web")], prompt: "Old task.", notes: "Note."))

    #expect(Array(brief.includedSections.prefix(3)) == [.heading, .convention, .agent])
    #expect(brief.text.contains("Branch: vibe/refonte-facturation"))
  }

  @Test("With a convention, the folders are not listed a second time")
  func noFolders() {
    let brief = SessionContextBriefBuilder()(for: session([worktree("api"), inPlace("web")]))

    #expect(!brief.includedSections.contains(.folders))
  }

  @Test("Under a tight budget the convention stays, summarised, while the rest goes")
  func neverDropped() {
    let repositories = (1...10).map { worktree("repository-with-a-long-name-\($0)") }
    let subject = session(repositories, prompt: "Old task.", notes: "Note.")
    let full = SessionContextBriefBuilder(byteLimit: 1_000_000)(for: subject)
    let brief = SessionContextBriefBuilder(byteLimit: full.text.utf8.count - 300)(for: subject)

    #expect(brief.includedSections.contains(.convention))
    #expect(!brief.includedSections.contains(.task))
    #expect(brief.text.contains("- and 9 more, attached the same way"))
    #expect(brief.isTruncated)
  }
}
