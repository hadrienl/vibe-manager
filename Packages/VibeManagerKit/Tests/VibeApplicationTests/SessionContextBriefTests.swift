import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Summarising a session for a fresh agent")
struct SessionContextBriefTests {
  private func session(
    name: String = "Refactor the webhook",
    prompt: String = "Split the signature check out.",
    notes: String? = "The retry path is still untested.",
    repositories: [RepositoryContext] = [
      RepositoryContext(
        rootPath: "/work/app",
        git: GitSnapshot(
          repositoryRootPath: "/work/app",
          branchName: "feat/webhook",
          headRevision: "1a2b3c4d5e6f",
          isDirty: true,
          capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      )
    ]
  ) -> WorkSession {
    WorkSession(
      name: name,
      initialPrompt: prompt,
      agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "opus"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
      closedAt: Date(timeIntervalSince1970: 1_700_000_100),
      repositories: repositories,
      notes: notes
    )
  }

  @Test("Everything the session carries is in the summary, and nothing else")
  func carriesWhatTheSessionHas() {
    let brief = SessionContextBriefBuilder()(for: session())

    #expect(brief.text.contains("Refactor the webhook"))
    #expect(brief.text.contains("claude-code · opus"))
    #expect(brief.text.contains("/work/app"))
    #expect(brief.text.contains("branch feat/webhook"))
    #expect(brief.text.contains("at 1a2b3c4"))
    #expect(brief.text.contains("with uncommitted changes"))
    #expect(brief.text.contains("The retry path is still untested."))
    #expect(brief.text.contains("Split the signature check out."))
    #expect(!brief.isTruncated)
  }

  @Test("A recorded Git snapshot is dated, never stated in the present")
  func gitSnapshotIsDated() {
    let brief = SessionContextBriefBuilder()(for: session())

    #expect(brief.text.contains("recorded "))
    #expect(brief.text.contains("as they were when this was recorded"))
  }

  @Test("The initial instruction is quoted as history, not handed back as the task")
  func promptIsQuotedAsHistory() {
    let brief = SessionContextBriefBuilder()(for: session())

    #expect(brief.text.contains("The instruction this session was created with, for context:"))
    #expect(brief.text.contains("Pick this work up from the current state of these files."))
  }

  @Test("An empty section is left out rather than rendered as none")
  func emptySectionsAreOmitted() {
    let brief = SessionContextBriefBuilder()(
      for: session(prompt: "   ", notes: nil, repositories: [])
    )

    #expect(!brief.includedSections.contains(.notes))
    #expect(!brief.includedSections.contains(.task))
    #expect(!brief.includedSections.contains(.folders))
    #expect(!brief.text.contains("Notes"))
    #expect(!brief.text.contains("Folders"))
  }

  @Test("The same session always produces the same summary")
  func isDeterministic() {
    let subject = session()
    let builder = SessionContextBriefBuilder()

    // Two separate builds of the same session, named so that what is being compared is two
    // *runs* and not one expression written twice.
    let first = builder(for: subject).text
    let second = builder(for: subject).text

    #expect(first == second)
  }

  @Test("Too long a summary drops whole sections, in order, and says that it was shortened")
  func truncatesBySection() {
    let builder = SessionContextBriefBuilder(byteLimit: 700)
    let long = String(repeating: "a", count: 2_000)

    let brief = builder(for: session(prompt: long, notes: long))

    #expect(brief.isTruncated)
    #expect(!brief.includedSections.contains(.task))
    #expect(!brief.includedSections.contains(.notes))
    #expect(brief.includedSections.contains(.heading))
    #expect(brief.includedSections.contains(.instruction))
    #expect(brief.text.contains("(This summary was shortened to fit.)"))
    #expect(brief.text.utf8.count <= 700)
  }

  @Test("A megabyte of notes still yields a summary an agent can be started with")
  func staysUnderTheAgentLimit() {
    let brief = SessionContextBriefBuilder()(
      for: session(notes: String(repeating: "note. ", count: 200_000))
    )

    #expect(brief.text.utf8.count <= AgentPromptLimits.argumentByteLimit)
    #expect(brief.isTruncated)
  }

  @Test("Clamping an edited summary keeps it valid, and leaves a short one alone")
  func clampsEditedText() {
    let builder = SessionContextBriefBuilder(byteLimit: 16)

    #expect(builder.clamped("short") == "short")
    // Cut by characters, so a multi-byte scalar is never sliced in half.
    let clamped = builder.clamped(String(repeating: "é", count: 40))
    #expect(clamped.utf8.count <= 16)
    #expect(clamped.allSatisfy { $0 == "é" })
  }
}
