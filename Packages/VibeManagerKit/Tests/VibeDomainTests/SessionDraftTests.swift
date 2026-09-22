import Foundation
import Testing
import VibeDomain

@Suite("The draft of a session")
struct SessionDraftTests {
  @Test("An empty draft reports every problem at once, not the first one")
  func emptyDraftReportsEveryProblem() {
    let issues = SessionDraft().validate()

    #expect(issues.contains(.nameMissing))
    #expect(issues.contains(.workingDirectoryMissing))
    #expect(issues.contains(.agentMissing))
  }

  @Test("A name made of spaces is not a name")
  func whitespaceNameIsRejected() {
    let draft = SessionDraft(
      name: "   \n ",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp"
    )

    #expect(draft.validate() == [.nameMissing])
  }

  @Test("A complete draft has nothing to report")
  func completeDraftIsAccepted() {
    let draft = SessionDraft(
      name: "Refactor the webhook",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp"
    )

    #expect(draft.validate().isEmpty)
  }

  @Test("An identity that cannot be stored is reported on the appearance, not on the name")
  func appearanceProblemIsFiledOnItsOwnField() {
    var draft = SessionDraft(
      name: "Refactor the webhook",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp"
    )
    draft.appearance = SessionAppearance(symbolName: "", colorHex: "not-a-colour")

    let issues = draft.validate()

    #expect(issues == [.appearanceInvalid])
    #expect(SessionDraftIssue.appearanceInvalid.field == .appearance)
  }

  @Test("A relative path is refused before anything tries to enter it")
  func relativePathIsRejected() {
    let draft = SessionDraft(
      name: "Session",
      providerID: "claude-code",
      workingDirectoryPath: "Developer/app"
    )

    #expect(draft.validate() == [.workingDirectoryNotAbsolute])
  }

  @Test("A tilde path is expanded rather than refused")
  func tildePathIsExpanded() {
    let draft = SessionDraft(
      name: "Session",
      providerID: "claude-code",
      workingDirectoryPath: "~/Developer"
    )

    #expect(draft.resolvedWorkingDirectoryPath == NSHomeDirectory() + "/Developer")
    #expect(draft.validate().isEmpty)
  }

  @Test("The identity derived from a name never moves between two runs")
  func derivedAppearanceIsStable() {
    let first = SessionAppearanceCatalog.derived(forName: "Refactor the webhook")
    let second = SessionAppearanceCatalog.derived(forName: "  refactor the WEBHOOK ")

    #expect(first == second)
    #expect(SessionAppearanceCatalog.contains(first))
    #expect(first != SessionAppearanceCatalog.derived(forName: "Write the release notes"))
  }

  @Test("A nameless draft wears the placeholder, not a colour it did not choose")
  func namelessDraftUsesPlaceholder() {
    #expect(SessionDraft().effectiveAppearance == SessionAppearanceCatalog.placeholder)
  }

  @Test("An explicit choice stops following the name")
  func explicitAppearanceWins() {
    var draft = SessionDraft(name: "Refactor the webhook")
    draft.appearance = SessionAppearance(symbolName: "bolt", colorHex: "#B42318")
    draft.name = "Something else entirely"

    #expect(draft.effectiveAppearance.symbolName == "bolt")
    #expect(draft.effectiveAppearance.colorHex == "#B42318")
  }

  @Test("The session a draft becomes is closed, named and rooted in its folder")
  func draftBecomesAValidSession() throws {
    let draft = SessionDraft(
      name: "  Refactor the webhook  ",
      initialPrompt: "Split the signature check out.",
      providerID: "claude-code",
      workingDirectoryPath: "/tmp"
    )

    let session = draft.session()

    #expect(session.name == "Refactor the webhook")
    #expect(session.status == .closed)
    #expect(session.agent?.providerID == "claude-code")
    // No model chosen means no model stored — never a sentinel that would reach `--model`.
    #expect(session.agent?.modelID == nil)
    #expect(session.repositories.map(\.path) == ["/tmp"])
    try session.validate()
  }

  @Test("A session without a model is a valid session")
  func agentWithoutModelIsValid() throws {
    var session = WorkSession(name: "Session")
    session.agent = SessionAgentConfiguration(providerID: "claude-code")

    try session.validate()
  }

  @Test("An empty model identifier is still refused")
  func emptyModelIdentifierIsRejected() {
    var session = WorkSession(name: "Session")
    session.agent = SessionAgentConfiguration(providerID: "claude-code", modelID: "")

    #expect(throws: WorkSessionValidationError.emptyAgentIdentifier) {
      try session.validate()
    }
  }
}
