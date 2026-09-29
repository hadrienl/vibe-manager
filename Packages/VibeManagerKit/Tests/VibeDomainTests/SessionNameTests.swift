import Foundation
import Testing
import VibeDomain

@Suite("What a session may be called")
struct SessionNameTests {
  @Test("The spaces around a name are dropped, and a pasted line break becomes a space")
  func normalization() {
    #expect(SessionName.normalized("  Fix the login  ") == "Fix the login")
    #expect(SessionName.normalized("Fix\nthe\tlogin\r\n") == "Fix the login")
  }

  @Test("An empty name, or one of spaces only, is refused as missing")
  func emptyNameIsRefused() {
    #expect(SessionName.validated("") == .failure(.nameMissing))
    #expect(SessionName.validated(" \n\t ") == .failure(.nameMissing))
  }

  @Test("120 characters are accepted, 121 are refused")
  func lengthLimit() {
    let longest = String(repeating: "a", count: SessionName.maximumLength)
    #expect(SessionName.validated(longest) == .success(longest))
    #expect(SessionName.validated(longest + "a") == .failure(.nameTooLong))
    #expect(SessionDraftIssue.nameTooLong.field == .name)
  }

  @Test("An emoji counts as one character, however many bytes it takes")
  func emojiCountsAsOne() {
    let name = String(repeating: "👩‍💻", count: SessionName.maximumLength)
    #expect(SessionName.validated(name) == .success(name))
  }

  @Test("The spaces around a long name do not count")
  func surroundingSpacesDoNotCount() {
    let longest = String(repeating: "a", count: SessionName.maximumLength)
    #expect(SessionName.validated("   \(longest)   ") == .success(longest))
  }

  @Test("A shortened name ends on a whole word, the ellipsis included in the length")
  func shortening() {
    let line = String(repeating: "word ", count: 40)
    let short = SessionName.shortened(line)
    #expect(short.count <= SessionName.maximumLength)
    #expect(short.hasSuffix("word…"))
  }

  @Test(
    "A session stored with a longer name still validates: the rule is checked where names come in")
  func storedLongNameStillValidates() throws {
    let session = WorkSession(name: String(repeating: "a", count: 200))
    try session.validate()
  }
}

@Suite("The default identity of a session")
struct SessionDefaultAppearanceTests {
  private let icon = SessionIconID(sha256: String(repeating: "a", count: 64))!

  @Test("It is what a creation gives the same name and the same folder icon")
  func matchesCreation() {
    var draft = SessionDraft(name: "Refactor the webhook")
    #expect(
      SessionAppearanceCatalog.defaultAppearance(forName: "Refactor the webhook", projectIcon: nil)
        == draft.effectiveAppearance)

    draft.projectIcon = ProjectIcon(id: icon, pngData: Data([1]))
    let appearance = SessionAppearanceCatalog.defaultAppearance(
      forName: "Refactor the webhook", projectIcon: icon)
    #expect(appearance == draft.effectiveAppearance)
    #expect(appearance.iconID == icon)
    #expect(
      appearance.symbolName
        == SessionAppearanceCatalog.derived(forName: "Refactor the webhook").symbolName)
  }
}

@Suite("The name of a draft")
struct SessionDraftNameLengthTests {
  @Test("A typed name that is too long is refused at creation too")
  func typedNameTooLong() {
    let draft = SessionDraft(
      name: String(repeating: "a", count: SessionName.maximumLength + 1),
      providerID: "claude-code", workingDirectoryPath: "/tmp")
    #expect(draft.validate() == [.nameTooLong])
  }

  @Test("A name a template makes is cut to the limit rather than refused")
  func suggestedNameIsCut() {
    let long = String(repeating: "word ", count: 40)
    let template = PromptTemplate(name: long, body: "Do it")
    let draft = SessionDraft(
      providerID: "claude-code", workingDirectoryPath: "/tmp",
      templateFill: PromptTemplateFill(template: template))
    #expect(draft.effectiveName.count <= SessionName.maximumLength)
    #expect(!draft.effectiveName.isEmpty)
  }
}
