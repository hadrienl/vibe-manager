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

  @Test("A name already used by another template is refused")
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

  @Test("Moving keeps the order the user chose")
  func move() {
    var library = library(["A", "B", "C"])
    let c = library.templates[2].id
    library.move(c, toPosition: 0)
    #expect(library.templates.map(\.name) == ["C", "A", "B"])
    library.move(c, by: 1)
    #expect(library.templates.map(\.name) == ["A", "C", "B"])
    library.move(c, by: 5)
    #expect(library.templates.map(\.name) == ["A", "B", "C"])
  }

  @Test("A template is deleted once, for good")
  func delete() {
    var library = library(["A", "B"])
    let a = library.templates[0].id
    let deleted = library.delete(a)
    let deletedTwice = library.delete(a)
    #expect(deleted)
    #expect(!deletedTwice)
    #expect(library.templates.map(\.name) == ["B"])
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
    #expect(fill.sessionName() == "Review 1")
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

@Suite("Keeping part of a value")
struct PromptTemplateExtractionTests {
  private let mergeRequest = "https://gitlab.com/group/project/-/merge_requests/1315/diffs#note_42"

  @Test("A pattern is read up to its unescaped slash, braces and bars included")
  func patternIsParsed() {
    let parsed = PromptTemplateSyntax.parse(
      #"MR {{ url? | /(?:merge_requests|pull)\/(\d{1,6})/ }}!"#)
    let placeholder = parsed.placeholders.first
    #expect(placeholder?.key == "url")
    #expect(placeholder?.isOptional == true)
    #expect(placeholder?.pattern == #"(?:merge_requests|pull)\/(\d{1,6})"#)
    #expect(parsed.segments.last == .text("!"))
    #expect(parsed.malformed.isEmpty)
  }

  @Test(
    "A pattern left open, or split over two lines, is text",
    arguments: [
      #"{{url|/\d+}}"#, "{{url|/\\d\n+/}}", "{{url|}}", "{{url|x/}}",
    ])
  func unfinishedPatternIsText(_ text: String) {
    #expect(PromptTemplateSyntax.parse(text).placeholders.isEmpty)
  }

  @Test("The first match is kept, or its first group when there is one")
  func firstMatchOrGroup() {
    #expect(PromptTemplateExtraction(pattern: #"\d+$"#).apply(to: "a/12/34") == .extracted("34"))
    #expect(
      PromptTemplateExtraction(pattern: #"merge_requests\/(\d+)"#).apply(to: mergeRequest)
        == .extracted("1315"))
    #expect(PromptTemplateExtraction(pattern: #"\d+$"#).apply(to: mergeRequest) == .extracted("42"))
    #expect(PromptTemplateExtraction(pattern: #"pull\/(\d+)"#).apply(to: mergeRequest) == .noMatch)
  }

  @Test("An invalid pattern says why, and keeps the template from being saved")
  func invalidPattern() {
    #expect(PromptTemplateExtraction(pattern: "(").problem != nil)
    let template = PromptTemplate(name: "T", sessionNamePattern: "R {{url|/(/}}", body: "{{url}}")
    #expect(template.problems(among: []).map(\.field) == [.sessionName])
  }

  @Test("The session name and the prompt use what the pattern keeps")
  func renderingExtracts() {
    var fill = PromptTemplateFill(
      template: PromptTemplate(
        name: "Review", sessionNamePattern: #"Review !{{url|/merge_requests\/(\d+)/}}"#,
        body: #"Review {{url}} (MR {{url|/merge_requests\/(\d+)/}})."#))
    fill.setValue(mergeRequest, for: "url")
    #expect(fill.sessionName() == "Review !1315")
    #expect(fill.render().prompt == "Review \(mergeRequest) (MR 1315).")
  }

  @Test("A value the pattern does not match adds nothing, and is said, not refused")
  func noMatchIsSaid() {
    var fill = PromptTemplateFill(
      template: PromptTemplate(name: "T", body: #"MR {{url|/pull\/(\d+)/}}."#))
    fill.setValue(mergeRequest, for: "url")
    let rendered = fill.render()
    #expect(rendered.prompt == "MR .")
    #expect(rendered.parts.contains(.unmatched(key: "url", label: "Url", pattern: #"pull\/(\d+)"#)))
    #expect(fill.missingRequiredFields.isEmpty)
  }

  @Test("Each pattern of a field is listed once, with where it is used")
  func extractionsOfAField() {
    let template = PromptTemplate(
      name: "T", sessionNamePattern: #"R {{url|/\d+$/}}"#,
      body: #"{{url|/\d+$/}} {{url|/(\w+)$/}} {{url}}"#)
    let uses = template.extractions(for: "url")
    #expect(uses.map(\.pattern) == [#"\d+$"#, #"(\w+)$"#])
    #expect(uses.first?.placesLabel == "Session name, Prompt")
  }

  @Test("Making the field optional keeps its pattern")
  func optionalKeepsPattern() {
    var template = PromptTemplate(name: "T", body: #"{{url|/\d+/}}"#)
    template.setRequired(false, for: "url")
    #expect(template.body == #"{{url?|/\d+/}}"#)
  }
}
