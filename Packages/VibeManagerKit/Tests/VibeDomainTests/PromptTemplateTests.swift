import Foundation
import Testing
import VibeDomain

@Suite("Reading placeholders in a template")
struct PromptTemplateSyntaxTests {
  private func keys(_ text: String) -> [String] {
    PromptTemplate(name: "T", body: text).fields.map(\.name)
  }

  @Test("{{url}}, {{ url }} and {{URL}} are one field")
  func spellingsAreOneField() {
    #expect(keys("Review {{url}} then {{ url }} and {{URL}}") == ["url"])
  }

  @Test("A field marked optional once is optional everywhere")
  func optionalOnceIsOptionalEverywhere() {
    let template = PromptTemplate(name: "T", body: "{{focus}} and {{focus?}}")
    #expect(template.fields.first?.isRequired == false)
  }

  @Test(
    "Braces that are not a name stay text, and are pointed out",
    arguments: [
      "{{payload.url}}", "{{ items[0] }}", "{{}}", "{{#each}}", "{{ 1abc }}",
    ])
  func malformedStaysText(_ text: String) {
    let parsed = PromptTemplateSyntax.parse("a \(text) b")
    #expect(parsed.placeholders.isEmpty)
    #expect(parsed.malformed.count == 1)
    #expect(parsed.segments == [.text("a \(text) b")])
  }

  @Test("\\{{ writes the braces and creates no field")
  func escapedBracesAreText() {
    let parsed = PromptTemplateSyntax.parse("Use \\{{url}} literally")
    #expect(parsed.placeholders.isEmpty)
    #expect(parsed.segments == [.text("Use {{url}} literally")])
  }

  @Test("Lone braces do not swallow a field further on the line")
  func loneBracesKeepLaterField() {
    #expect(keys("Write `{{` then review {{url}}") == ["url"])
  }

  @Test("Fields come in the order they are first read, the session name first")
  func fieldOrder() {
    let template = PromptTemplate(
      name: "T", sessionNamePattern: "Review {{mr}}", body: "{{focus}} on {{repo}} for {{mr}}")
    #expect(template.fields.map(\.name) == ["mr", "focus", "repo"])
  }

  @Test("A label is derived from the name until one is chosen")
  func derivedLabel() {
    var template = PromptTemplate(name: "T", body: "{{mr_url}}")
    #expect(template.fields.first?.label == "Mr url")
    template.updateSettings(for: "mr_url") { $0.label = "Merge request" }
    #expect(template.fields.first?.label == "Merge request")
  }

  @Test("Making a field optional writes its ? everywhere it appears")
  func settingRequiredRewritesText() {
    var template = PromptTemplate(
      name: "T", sessionNamePattern: "R {{url}}", body: "At {{ url }} and {{URL}}.")
    template.setRequired(false, for: "url")
    #expect(template.sessionNamePattern == "R {{url?}}")
    #expect(template.body == "At {{url?}} and {{URL?}}.")
    template.setRequired(true, for: "url")
    #expect(template.body == "At {{url}} and {{URL}}.")
  }

  @Test("Positions are counted in UTF-16, the unit a text view highlights by")
  func utf16Ranges() {
    let parsed = PromptTemplateSyntax.parse("👍 {{x}}")
    #expect(parsed.placeholders.first?.range == 3..<8)
  }

  @Test("More than twenty fields is a problem")
  func tooManyFields() {
    let body = (1...21).map { "{{f\($0)}}" }.joined(separator: " ")
    let problems = PromptTemplate(name: "T", body: body).problems(among: [])
    #expect(problems == [.tooManyFields(21)])
  }
}

@Suite("Filling a template in")
struct PromptTemplateFillTests {
  private let review = PromptTemplate(
    name: "Review",
    sessionNamePattern: "Review {{url}}",
    body: "Review {{url}}. Again: {{url}}.\n\n{{focus?}}",
    fieldSettings: [PromptTemplateFieldSettings(name: "focus", isMultiline: true)]
  )

  @Test("A value is inserted as it is and never read again")
  func valueIsNotReinterpreted() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue("{{focus}} $(whoami) `x` --help", for: "url")
    #expect(
      fill.render().prompt
        == "Review {{focus}} $(whoami) `x` --help. Again: {{focus}} $(whoami) `x` --help.")
  }

  @Test("An optional field left empty leaves no dangling line")
  func emptyOptionalIsTrimmed() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue("https://example.com/1", for: "url")
    #expect(
      fill.render().prompt == "Review https://example.com/1. Again: https://example.com/1.")
  }

  @Test("Line breaks become \\n, and control characters go, tabs and newlines kept")
  func controlCharactersAreRemoved() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue("u", for: "url")
    fill.setValue("one\r\ntwo\rthree\u{1B}[31m red\u{07}\tend\n\n", for: "focus")
    #expect(fill.render().prompt.hasSuffix("one\ntwo\nthree[31m red\tend"))
  }

  @Test("A one-line field stays on one line, without its surrounding spaces")
  func singleLineValue() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue("  https://example.com/1\n", for: "url")
    #expect(fill.render().prompt.hasPrefix("Review https://example.com/1. "))
  }

  @Test("A required field made of spaces is missing")
  func whitespaceIsMissing() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue("  \n ", for: "url")
    #expect(fill.missingRequiredFields.map(\.name) == ["url"])
    #expect(fill.render().editableText.hasPrefix("Review {{url}}."))
  }

  @Test("The session name is made on one line and cut at 80 characters")
  func sessionName() {
    var fill = PromptTemplateFill(template: review)
    fill.setValue(String(repeating: "a", count: 200), for: "url")
    let name = fill.sessionName()
    #expect(name?.count == PromptTemplateLimits.sessionNameLength)
    #expect(name?.hasPrefix("Review aaa") == true)
  }

  @Test("The byte count is in UTF-8")
  func byteCount() {
    var fill = PromptTemplateFill(template: PromptTemplate(name: "T", body: "{{x}}"))
    fill.setValue("é👍", for: "x")
    #expect(fill.render().byteCount == 6)
  }
}

@Suite("The library of templates")
struct PromptTemplateLibraryTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000)

  private func library(_ names: [String]) -> PromptTemplateLibrary {
    PromptTemplateLibrary(templates: names.map { PromptTemplate(name: $0, body: "Do \($0)") })
  }

  @Test("Saving a known template takes the next revision")
  func saveBumpsRevision() throws {
    var library = PromptTemplateLibrary()
    var template = try library.save(PromptTemplate(name: "Review", body: "{{url}}"), at: now)
    #expect(template.revision == 1)
    template.body = "Review {{url}}"
    template = try library.save(template, at: now)
    #expect(template.revision == 2)
  }

  @Test("A name already used by another active template is refused")
  func duplicateNameRefused() {
    var library = library(["Review"])
    #expect(throws: PromptTemplateRejected.self) {
      try library.save(PromptTemplate(name: "review", body: "x"), at: now)
    }
  }

  @Test("Settings of fields gone from the text are dropped on save")
  func orphanSettingsDropped() throws {
    var library = PromptTemplateLibrary()
    var template = PromptTemplate(name: "T", body: "{{a}}")
    template.updateSettings(for: "a") { $0.label = "A" }
    template.updateSettings(for: "gone") { $0.label = "Gone" }
    let saved = try library.save(template, at: now)
    #expect(saved.fieldSettings.map(\.name) == ["a"])
  }

  @Test("A copy goes right after its original, under a name of its own")
  func duplicate() {
    var library = library(["A", "B"])
    let copy = library.duplicate(library.templates[0].id, at: now)
    #expect(library.templates.map(\.name) == ["A", "A copy", "B"])
    #expect(copy?.revision == 1)
    library.duplicate(library.templates[0].id, at: now)
    #expect(library.templates[1].name == "A copy 2")
  }

  @Test("Moving and archiving keep the order the user chose")
  func moveAndArchive() {
    var library = library(["A", "B", "C"])
    let c = library.templates[2].id
    library.move(c, toActivePosition: 0)
    #expect(library.active.map(\.name) == ["C", "A", "B"])
    library.move(c, by: 1)
    #expect(library.active.map(\.name) == ["A", "C", "B"])
    library.archive(library.templates[0].id, at: now)
    #expect(library.active.map(\.name) == ["C", "B"])
    library.unarchive(library.archived[0].id)
    #expect(library.active.map(\.name) == ["C", "B", "A"])
  }

  @Test("Only an archived template can be deleted")
  func deleteNeedsArchive() {
    var library = library(["A"])
    let id = library.templates[0].id
    let refused = library.delete(id)
    #expect(refused == false)
    library.archive(id, at: now)
    let deleted = library.delete(id)
    #expect(deleted)
    #expect(library.templates.isEmpty)
  }

  @Test("The examples are added once, and only when asked")
  func examples() {
    var library = PromptTemplateLibrary()
    #expect(library.isMissingExamples)
    let first = library.addExamples(at: now)
    let second = library.addExamples(at: now)
    #expect(first.count == 2)
    #expect(second.isEmpty)
    #expect(!library.isMissingExamples)
    let review = PromptTemplateExamples.reviewID
    library.archive(review, at: now)
    library.delete(review)
    #expect(library.templates.count == 1)
    let again = library.addExamples(at: now)
    #expect(again.map(\.id) == [review])
  }

  @Test("The examples fill in without surprises")
  func examplesRender() {
    var fill = PromptTemplateFill(template: PromptTemplateExamples.review(createdAt: now))
    #expect(fill.template.fields.map(\.name) == ["url", "focus"])
    #expect(fill.missingRequiredFields.map(\.label) == ["Merge request URL"])
    fill.setValue("https://gitlab.com/g/p/-/merge_requests/1", for: "url")
    #expect(fill.missingRequiredFields.isEmpty)
    #expect(fill.sessionName() == "Review https://gitlab.com/g/p/-/merge_requests/1")
    #expect(fill.render().prompt.hasSuffix("Do not push anything."))
  }

  @Test("An import says what is new, identical, changed or skipped")
  func importPlan() {
    var library = library(["A", "B"])
    var changed = library.templates[1]
    changed.body = "Something else"
    let new = PromptTemplate(name: "C", body: "c")
    let invalid = PromptTemplate(name: "", body: "x")
    let plan = library.planImport([library.templates[0], changed, new, invalid])
    #expect(
      plan.entries.map(\.outcome) == [.identical, .changed, .new, .skipped("A name is required.")])

    let keepBoth = library
    library.apply(plan, replacing: [changed.id], at: now)
    #expect(library.templates.map(\.name) == ["A", "B", "C"])
    #expect(library.templates[1].body == "Something else")
    #expect(library.templates[1].revision == 2)

    var both = keepBoth
    both.apply(plan, at: now)
    #expect(both.templates.map(\.name) == ["A", "B", "B 2", "C"])
    #expect(both.templates[1].body == "Do B")
  }
}
