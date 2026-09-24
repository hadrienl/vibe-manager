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

@Suite("A draft filled from a template")
struct TemplateDraftTests {
  private func draft(url: String) -> SessionDraft {
    var fill = PromptTemplateFill(
      template: PromptTemplate(
        name: "Review", sessionNamePattern: "Review {{url}}", body: "Review {{url}}.",
        revision: 3))
    fill.setValue(url, for: "url")
    return SessionDraft(
      name: "Review", initialPrompt: "ignored", providerID: "claude-code",
      workingDirectoryPath: "/tmp", templateFill: fill)
  }

  @Test("An empty required field is a problem of its own")
  func requiredFieldMissing() {
    let issues = draft(url: " ").validate()
    #expect(issues.count == 1)
    #expect(issues.first?.field == .templateField)
    #expect(issues.first?.fieldKey == "url")
  }

  @Test("The session keeps the rendered prompt and where it came from")
  func sessionKeepsRenderedPrompt() {
    let draft = draft(url: "https://x/1")
    let session = draft.session()
    #expect(session.initialPrompt == "Review https://x/1.")
    #expect(session.template?.name == "Review")
    #expect(session.template?.revision == "3")
    #expect(session.template?.id == draft.templateFill?.template.id.description)
  }

  @Test("A free prompt carrying control characters is refused")
  func controlCharactersInFreePrompt() {
    let draft = SessionDraft(
      name: "S", initialPrompt: "colour \u{1B}[31m", providerID: "claude-code",
      workingDirectoryPath: "/tmp")
    #expect(draft.validate() == [.promptControlCharacters])
  }
}

@Suite("Line breaks pasted into a free prompt")
struct FreePromptLineBreakTests {
  @Test("\\r\\n and \\r are line breaks, not control characters to refuse")
  func carriageReturnsAreLineBreaks() {
    let draft = SessionDraft(
      name: "S", initialPrompt: "one\r\ntwo\rthree", providerID: "claude-code",
      workingDirectoryPath: "/tmp")
    #expect(draft.validate().isEmpty)
    #expect(draft.session().initialPrompt == "one\ntwo\nthree")
  }
}
