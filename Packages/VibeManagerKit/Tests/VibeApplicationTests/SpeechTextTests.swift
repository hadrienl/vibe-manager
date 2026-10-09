import Foundation
import Testing

@testable import VibeApplication

@Suite("What is read of an answer (#357)")
struct SpeechTextTests {
  @Test("Code is left out, and the marks of Markdown are taken away, their words kept")
  func readable() {
    let markdown = """
      ## Done

      I fixed **the build** in `Package.swift`, see [the PR](https://github.com/x/y/pull/1).

      ```swift
      let x = 1
      ```

      - first point
      - second_point

      | file | state |
      |------|-------|
      | a.swift | ok |
      """
    #expect(
      SpeechText.readable(fromMarkdown: markdown)
        == """
        Done.
        I fixed the build in Package.swift, see the PR.
        first point second_point.
        file, state a.swift, ok.
        """)
  }

  @Test("An answer made of code alone has nothing to read")
  func codeOnly() {
    #expect(SpeechText.readable(fromMarkdown: "```\nrm -rf build\n```") == "")
  }

  @Test("The language read by default is the user's, when the voice reads it")
  func preferredLanguage() {
    #expect(SpeechLanguage.preferred(for: Locale(identifier: "fr_FR")) == .french)
    #expect(SpeechLanguage.preferred(for: Locale(identifier: "nl_NL")) == .english)
  }
}
