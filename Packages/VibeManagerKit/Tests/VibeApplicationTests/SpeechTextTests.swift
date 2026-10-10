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

@Suite("How much the voice buffers before its first word (#357)")
struct SpeechPaceTests {
  @Test("A short answer starts at once; a long one buffers what the voice would fall behind")
  func buffer() {
    let pace = SpeechPace()
    #expect(pace.buffer(for: "Oui.") < 0.7)
    // 210 characters, about 14 s of speech, generated at 0.9× real time: 1.4 s behind, half as
    // much again, and the margin.
    let answer = String(repeating: "a", count: 210)
    #expect(abs(pace.buffer(for: answer) - 2.6475) < 0.01)
    // Never more than six seconds, however long the answer.
    #expect(pace.buffer(for: String(repeating: "a", count: 100_000)) == 6)
  }

  @Test("The pace is learnt from the readings, one slow reading not undoing the others")
  func learns() {
    var pace = SpeechPace()
    let answer = String(repeating: "a", count: 210)
    pace.record(text: answer, audio: 14, generation: 14, wall: 15)
    #expect(abs(pace.speed - 0.95) < 0.001)
    pace.record(text: answer, audio: 14, generation: 28, wall: 30)
    #expect(abs(pace.speed - 0.725) < 0.001)
    // A reading too short to tell is not learnt from.
    pace.record(text: "Oui.", audio: 0.5, generation: 2, wall: 2)
    #expect(abs(pace.speed - 0.725) < 0.001)
  }
}
